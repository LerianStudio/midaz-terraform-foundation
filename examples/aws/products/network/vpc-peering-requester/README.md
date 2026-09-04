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

The plan fails when a peer CIDR overlaps the local VPC CIDR. AWS **accepts** a
peering between overlapping blocks and then never routes over it: the more
specific local route wins, packets stay inside the local VPC, and the failure
shows up in the other account as an unreachable service with nothing logged
anywhere. Plan time is the only cheap place to catch it.

Blocks on this estate: control plane `10.59.0.0/16`, staging `10.61.0.0/16`,
production `10.60.0.0/16`.

## What it does not do

No `requester`/`accepter` DNS-resolution options block: the control plane is
reached through a public hosted zone that answers with the private ALB address
(`tm-int.devops.consignado.lerian.dev`), not through cross-VPC private DNS. No
`peer_region`: one region. And no staging↔production entry, ever — the stacks
are peered with the control plane and never with each other.
