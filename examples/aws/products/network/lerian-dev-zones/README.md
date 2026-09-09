# products/network/lerian-dev-zones

Creates **one** public hosted zone under the `lerian.dev` apex, plus a wildcard
certificate for it. Three zones exist in this scheme, and each one is a separate
apply against a separate state.

| zone | AWS account | Terraform environment |
|---|---|---|
| `prd.lerian.dev` | 862902859103 | `prd` |
| `stg.lerian.dev` | 862902859103 | `stg` |
| `devops.lerian.dev` | 159142082896 | `dev` |

The pairing is fixed in `main.tf` and checked at plan time. AWS accepts any
pairing you hand it, and a wrong one puts one environment's DNS in another
environment's state, where a destroy of the second removes the DNS the first
believes it owns.

## Why this root exists next to `products/lerian-platform/dns`

That root creates one zone per Terraform environment, and all three of its states
are occupied by the older `*.consignado.lerian.dev` scheme. Repointing any of them
at a new name would replace a zone whose old name is still live — its
`prevent_destroy` turns that into a failed plan rather than a quiet outage. A
separate root leaves all three intact, which is what lets the two schemes coexist
while consumers move over one at a time.

## Three differences from `products/lerian-platform/dns`

**`wait_for_validation` defaults to `false`.** The apex lives in the
organisation's management account, so the delegation is always a later step by
somebody else. A blocking wait would spend its whole timeout on a step that had
not started. With it off the apply completes, `certificate_validated` reports
false, and ACM retries on its own for 72 hours — long enough for the delegation
to land, with no second apply. There is no window without TLS because there is no
window with traffic: nothing resolves until the delegation exists.

**One validation record instead of two.** `domain_validation_options` returns one
element per certificate name, and both carry an identical record because ACM
validates a wildcard through its parent's record. The older root keys its
`for_each` by `domain_name`, so two Terraform instances manage one Route 53
record, and `allow_overwrite` is what keeps that applying. This root requests only
the apex's element, and a `precondition` fails the apply if the two elements ever
stop being identical.

Keying by `resource_record_name` and `_type` — the obvious fix — is not possible:
those attributes are unknown until the certificate exists, and Terraform rejects a
`for_each` whose keys are unknown at plan time. The older root's key works
precisely *because* `domain_name` comes from the configuration.

**`zone_name` is a closed list, not a pattern.** The three names above are the
whole permitted set. A suffix check would accept the apex itself, a fourth
environment nobody agreed to, and `a.b.lerian.dev` — each of which creates an
orphan zone that resolves for nobody and a certificate that can never validate.
Adding a zone is a deliberate edit of `variables.tf` and of the environment map in
`main.tf`.

## Running it

```bash
cp envs/prd.tfvars-example envs/prd.tfvars   # then fill it in
terraform init \
  -backend-config=../../../backend/prd.hcl \
  -backend-config="key=aws/products/network/lerian-dev-zones/terraform.tfstate"
terraform apply -var-file=envs/prd.tfvars
terraform output delegation_lines
```

Only `envs/prd.tfvars-example` is committed, so the copy is the first step for
anyone driving this root directly. Estates that keep their tfvars in their own
repository — the consignado estate does, under `infra/envs/` — get the file
installed by their sync script instead, and MUST NOT edit it inside the managed
checkout: the next sync overwrites it and the change is invisible to review.

The state key carries no environment because the backend bucket does
(`lerian-tfstate-{environment}-{account_id}`), so the same key in two backends is
two states. That is what keeps `prd.lerian.dev` and `stg.lerian.dev` — same
account, same key — out of one state file.

## The manual step

`delegation_lines` prints one line: the zone name and its four name servers,
space separated, ready to paste. In the account holding `lerian.dev`, create an NS
record for that zone with those four values and TTL 300.

Paste it; do not retype it. Route53 hands out exactly four name servers per zone,
and a truncated set applies cleanly and resolves for as long as that one server
answers — then takes the whole zone off the internet the moment it does not.

## What this root does not do

It never writes to the apex, it installs no chart, and it publishes no
`txtOwnerId`. That last omission is deliberate and is the one most worth knowing
about: `external-dns` stamps every record it manages with the owner id and, under
`policy: sync`, deletes only what carries its own stamp. Both naming schemes are
live for the whole migration and the controller still owns the records in the old
zone, so re-stamping it with this zone's id orphans all of them at once, with
nothing left to clean them up. The owner id migrates once, explicitly, with
`--migrate-from-txt-owner` and a dry run, at cutover.
