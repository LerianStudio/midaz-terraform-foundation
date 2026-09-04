# `products/network/vpc-peering-accepter`

The application-stack side of a peering the control plane requested. The
tenant-manager runs in the control-plane account and provisions datastores that
live in this account, so the VPCs have to reach each other on private addresses.

Applies in the application account, **once per stack**: environment `stg`
(VPC `10.61.0.0/16`) and environment `prd` (VPC `10.60.0.0/16`). Its counterpart
is [`products/network/vpc-peering-requester`](../vpc-peering-requester), which
applies once, in the control-plane account.

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

## One directory, two states

This root is applied twice in the same AWS account and the state key carries no
environment. The two applies do not collide because the bucket does: `bootstrap`
names it `lerian-tfstate-{environment}-{account_id}`, so the environment lives in
the `-backend-config` file, not in the key.

That is why every input is **singular** — one `pcx_id`, one `peer_cidr`. Each
environment accepts its own peering, in its own state. Staging and production
routing never share a blast radius, and there is no staging↔production peering
to accept — the stacks are peered with the control plane and never with each
other.

## What goes in, what comes out

| | |
|---|---|
| In | `pcx_id` — one value of `pcx_ids` from the requester, for this stack |
| In | `peer_cidr` — the control plane block, `10.59.0.0/16` |
| In | `route_table_ids` — `terraform output private_route_table_ids` of `infra-base/vpc`, this environment |
| Out | `accepted_pcx_id`, `peer_cidr` — evidence of what was accepted and routed |

The local VPC is resolved by `tag:Name = "lerian-{environment}-vpc"`, so it takes
no input of its own.

## The overlap guard

The plan fails when `peer_cidr` overlaps the **local** VPC CIDR. The three blocks
are one character apart — control plane `10.59.0.0/16`, production `10.60.0.0/16`,
staging `10.61.0.0/16` — and writing the local block into `peer_cidr` does not
fail: AWS accepts the route, which then hijacks this VPC's own address space.
Nothing is logged; it surfaces as datastores in this account becoming
intermittently unreachable. Plan time is the only cheap place to catch it.

The guard is attached to the route, because the route is what carries the bad
value. `route_table_ids` is validated non-empty, so it is always reached.

## Routing is per direction

The acceptance alone carries no traffic, and neither does the requester's half.
The routes over there send packets from the control plane into this VPC; the
routes here send the replies back. Missing either side leaves the connection
`ACTIVE` and every call timing out.

## Destroying it

`aws_vpc_peering_connection_accepter` adopts a connection this account does not
own. Destroying this root removes the acceptance from state and returns the
connection to the requester's control — it does not delete the peering. The
routes go with it, which is the part that actually stops traffic.
