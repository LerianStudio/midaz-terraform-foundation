# `products/network/vpc-peering-requester`

The control-plane side of the two VPC peerings. The tenant-manager runs in the
control-plane account and provisions datastores that live in the application
account, so the VPCs have to reach each other on private addresses.

Applies in the control-plane account only, environment `dev`
(VPC `10.59.0.0/16`). Its counterpart is
[`products/network/vpc-peering-accepter`](../vpc-peering-accepter), which applies
in the application account, once per stack.

## Two applies, no clicks

A peering connection is two resources in two accounts. `auto_accept` only works
within one account, and a provider alias assuming a role across the boundary
would put one account's credentials in the other account's state — so the id
crosses as a reviewable value instead:

```
1. lerian-infra --env dev --target network/vpc-peering-requester --action apply
2. terraform output pcx_ids
     -> {"prd":"pcx-0a1b...","stg":"pcx-0c2d..."}
3. write each id into pcx_id in
     infra/envs/prd/products/network/vpc-peering-accepter/{stg,prd}.tfvars
4. lerian-infra --env stg --target network/vpc-peering-accepter --action apply
   lerian-infra --env prd --target network/vpc-peering-accepter --action apply
```

A pending request **expires after 7 days**. Step 4 is not optional homework.

## What comes out, what goes in

| | |
|---|---|
| Out | `pcx_ids` — one id per peer key, the input to the accepter |
| In | `route_table_ids` — `terraform output private_route_table_ids` of `infra-base/vpc`, this environment |
| In | `peers` — one entry per stack: `account_id`, `vpc_id`, `cidr` |

The local VPC is resolved by `tag:Name = "lerian-{environment}-vpc"`, so it takes
no input of its own.

## The overlap guard

The plan fails when a peer CIDR overlaps the local VPC CIDR. AWS **refuses**
such a peering — "you cannot create a VPC peering connection between VPCs that
have matching or overlapping IPv4 or IPv6 CIDR blocks" — but it refuses it late:
the create call returns an id, the request goes `initiating-request` → `failed`,
and the apply aborts with `unexpected state 'failed'` once that dead `pcx-` id
is already in state.

The guard buys exactly one thing: the same refusal at plan time, before any
resource is created, in a message that names the peer, both CIDRs and the blocks
this estate uses — instead of a state-machine string that names neither the tfvars
nor the value that was wrong. (Not before any API call: resolving the local VPC is
one, and it is where the local CIDR comes from.)

It compares against the CIDR **declared** for each peer in `peers`, not the one
its VPC really has. So it catches a declared block that overlaps this VPC, and it
has nothing to say about one that is simply wrong about a VPC it does not overlap.

Blocks on this estate: control plane `10.59.0.0/16`, staging `10.61.0.0/16`,
production `10.60.0.0/16`.

## Declared vs real, on the routes

A block that is wrong but disjoint is caught by a second guard, a precondition on
each route, which reads the connection back from the API. It has two moments,
because AWS only answers in one of them:

| | |
|---|---|
| First apply | **Declared value only.** The connection is still `pending-acceptance`, and "CIDR block information is only returned when describing an active VPC peering connection" (`describe-vpc-peering-connections`, `AccepterVpcInfo`) — there is nothing to compare with. Nothing is lost by letting the route through: a route to a pending connection "has a state of `blackhole`, and has no effect until the VPC peering connection is in the `active` state". |
| Every plan after acceptance | **Declared vs real.** The API now reports the accepter's block, and a plan whose `peers[*].cidr` disagrees with it is refused — naming the peer key, both blocks, and the tfvars entry to fix. Including the plans that only meant to add a route table. |

`destination_cidr_block` stays the **declared** value, so the first apply still
creates the (blackhole) route and the acceptance turns it live with no second
apply here.

This is the requester-side mirror of the `cidr_block` provenance check in
[`vpc-peering-accepter`](../vpc-peering-accepter), which reads the same
connection from the other end.

## What it does not do

No `requester`/`accepter` DNS-resolution options block: the control plane is
reached through a public hosted zone that answers with the private ALB address
(`tm-int.devops.consignado.lerian.dev`), not through cross-VPC private DNS. No
`peer_region`: one region. And no staging↔production entry, ever — the stacks
are peered with the control plane and never with each other.
