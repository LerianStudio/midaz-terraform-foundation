# `products/network/route53-delegation`

NS records in `consignado.lerian.dev` pointing at the child zones underneath it.
Applies in the application account (`862902859103`), environment `prd`, **once**:
that is where the parent zone lives.

## 1. It replaces the manual step

[`products/lerian-platform/dns`](../../lerian-platform/dns) creates a child zone
and emits its four name servers, then stops — its own README calls the record that
points at them "the one manual step on the whole estate". For every child under
`consignado.lerian.dev`, this root is that step:

```
1. lerian-infra --env <child env> --target lerian-platform/dns --action apply
2. terraform output name_servers
3. write it into `delegations` in
     infra/envs/prd/products/network/route53-delegation/prd.tfvars
4. lerian-infra --env prd --target network/route53-delegation --action apply
```

| | |
|---|---|
| In | `parent_zone_id` — `terraform output zone_id` of `lerian-platform/dns`, env `prd`, this account |
| In | `delegations` — child FQDN → its four name servers, one entry per child |
| Out | `delegated_children` — the FQDNs now delegated |

## 2. `devops.` and `stg.`, and nothing else

The children served from here are `devops.consignado.lerian.dev` (control plane
account) and `stg.consignado.lerian.dev` (this account). **`hml.` is not one of
them, now or later.**

The NS record for `hml.consignado.lerian.dev` does not live in this zone. It lives
in `lerian.dev`, in the management account (`Z08918942Z5HSMYZ002F`,
`infra/README.md` §"The manual step"; both `dns` tfvars carry
`parent_zone_name = "lerian.dev"`), which no root in this account reaches. Adding
`hml.` to `delegations` would create a delegation that always loses to the more
specific one upstream: it would apply cleanly, resolve for nobody, and read like a
working configuration. Removing the upstream record is a dated step of the
`cutover-trinus-staging` lane, when the hml zone dies.

## 3. No TLS window

ACM validates by resolving a record inside the child zone from the public
internet, so it cannot succeed before this delegation exists. The child `dns`
applies therefore set `wait_for_validation = false` — otherwise they stall 45
minutes and fail — and their `*.stg.` and `*.devops.` certificates issue on their
own, inside the 72 hours ACM keeps retrying, as soon as this root applies. There
is nothing to schedule and no window to coordinate.
