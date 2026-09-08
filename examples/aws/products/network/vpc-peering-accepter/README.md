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

The id is a hand-copied string, so this root does not take it on trust — see
[the provenance guard](#the-provenance-guard) below.

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
| In | `peer_account_id` — the control-plane account, `159142082896`; what the request has to have been opened by |
| In | `peer_cidr` — the control plane block, `10.59.0.0/16` |
| In | `route_table_ids` — `terraform output private_route_table_ids` of `infra-base/vpc`, this environment |
| Out | `accepted_pcx_id`, `peer_cidr` — evidence of what was accepted and routed |

The local VPC is resolved by `tag:Name = "lerian-{environment}-vpc"`, so it takes
no input of its own.

## The provenance guard

**The plan fails when `pcx_id` is not the request this tfvars describes.**

A peering id is an opaque handle and `auto_accept = true` accepts whatever it is
handed. Any AWS account can open a peering request against a VPC in this one — it
arrives silently, costs the opener nothing, and waits in `pending-acceptance`.
Accepting the wrong one and routing `peer_cidr` into it points this stack's
10.59.0.0/16 traffic at a VPC nobody here controls, and from inside the VPC that
is indistinguishable from a working control plane.

So the root reads the connection back (`data "aws_vpc_peering_connection"`) and
compares three facts with what the tfvars claims:

| Fact | Must equal | What it catches |
|---|---|---|
| `owner_id` | `peer_account_id` | a request opened by somebody else |
| `cidr_block` | `peer_cidr` | routes sent to a peering that cannot answer for that block |
| `peer_vpc_id` | the local VPC | the `stg`/`prd` entries of `pcx_ids` swapped — a real connection accepted in the wrong stack |

Field orientation, since it reads backwards once: from either side, `owner_id` /
`vpc_id` / `cidr_block` describe the **requester** (the control plane), and
`peer_*` describe the **accepter** (this stack).

This evaluates against a data source: a plan without credentials defers it to
apply, and it still runs before anything is accepted.

`tests/provenance.tftest.hcl` proves all three with `mock_provider "aws" {}` — no
credential, no AWS call. Coherent values plan clean; each of the three facts
diverging on its own is refused. `terraform test` with `mock_provider` needs
Terraform **>= 1.7** locally; the root's `required_version` floor stays `>= 1.5.0`,
and the foundation's CI does not run `terraform test` today.

## No CIDR-overlap guard, and why

The digit slip this estate is exposed to — control plane `10.59.0.0/16`,
production `10.60.0.0/16`, staging `10.61.0.0/16`, one character apart — is
already caught, one guard earlier. The `cidr_block` provenance check requires
`peer_cidr` to *equal* the CIDR the API reports for this connection's requester,
and AWS refuses to create a peering between overlapping CIDRs at all, so a
connection whose real requester block overlaps this VPC does not exist to be
accepted. Any other `peer_cidr` fails provenance on the accepter, before a route
is planned. An overlap guard on the route could only run after that check had
passed, on a value already proven equal to the real one.

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
