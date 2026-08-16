Cache for the plugin-br-pix-switch umbrella — three of the chart's ten
components use it. Root stack over
[`_modules/valkey-elasticache`](../../../_modules/valkey-elasticache).

One root, one datastore, one state file. See [`../README.md`](../README.md) for
the product-level picture: deploy order, the shared-vs-dedicated model, and the
full Helm mapping.

| | |
|---|---|
| Module | `../../../_modules/valkey-elasticache` |
| State key | `aws/products/plugin-br-pix-switch/valkey/terraform.tfstate` |
| Creates | `plugin-br-pix-switch-{env}-valkey` (ElastiCache replication group) |
| Secret | `plugin-br-pix-switch-{env}-valkey/auth-token` |
| Chart target | `VALKEY_URL` in `spi.secrets`, `dictHub.secrets`, `dictHubVsync.secrets` |
| Chart verified | plugin-br-pix-switch 2.0.0-beta.1+ |

The CRM deployment has no Redis variables at all.

## Run it

```bash
cd examples/aws/products/plugin-br-pix-switch/valkey

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/plugin-br-pix-switch/valkey/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

`../../../` is **three** levels up and lands on `examples/aws`, where both
`backend/` and `_modules/` live. Verified with `terraform init`.

Prerequisites: `infra-base/vpc`. `infra-base/eks` is optional at apply time —
see *Ingress* below.

## What this root decides

The module already resolves the VPC and the subnets by itself. This root exists
for three things the module cannot do:

1. **Derive the cross-stack names.** `lerian-{env}-vpc` and `lerian-{env}-eks`.
   Note the `lerian` prefix on both: they belong to `infra-base`, not to plugin-br-pix-switch.
   That is also why this root does **not** call the `naming` module.
2. **Compute the ingress allow list.**
3. **Translate to the chart**, which for Valkey is more than a rename — see
   below.

It creates no AWS resource of its own.

## Ingress

Identical to the sibling roots, because it is literally the same code: resolved
by [`_modules/product-network`](../../../_modules/product-network), called here
as `module.network` with `enabled = var.mode == "dedicated"`. `Type=private`
subnet CIDRs plus the EKS node security group, matched by
`tag:Name = "lerian-{env}-eks-node"`; `check "eks_node_security_group_resolved"`
lives in that module and warns while the lookup is empty. See its README for the
plural-data-source rule and the deploy-order window it covers.

> `var.subnet_tag_type` (`"database"`) selects the subnets the **replication
> group is placed in** and goes to `valkey-elasticache` only. `product-network`
> keeps its own default (`"private"`), the subnets whose CIDRs become
> **ingress**.

The "nothing can reach this cache at all" case is **not** re-asserted here: the
module already carries `check "ingress_is_reachable"` for it.

## The chart consumes a URL — so `helm_values` is empty

**This is the structural difference from every other product.** Read it before
copying anything from `products/midaz/valkey`.

The chart reads the cache through **one key**, and it is a full connection URL in
a Secret:

```yaml
spi:
  secrets:
    VALKEY_URL: "redis://default:<password>@valkey-host:6379/0"
```
(`values-template.yaml:44`, repeated at `:88` for `dictHub` and `:101` for
`dictHubVsync`)

There is **no** `REDIS_HOST`, no `REDIS_PORT`, no `REDIS_TLS`, no `REDIS_DB`, no
`MULTI_TENANT_*`. `<component>.secrets` is emitted verbatim
(`templates/spi/secrets.yaml:13-15`) and that is the whole contract.

Terraform cannot fill a secret. And unlike Postgres and Mongo, there is **no
leftover non-secret surface either**: the cache has no bootstrap Job, so there is
no `global.external*Definitions` block with a plain host and port.

So `helm_values` is **empty**, and the shape is published as
`valkey_url_template`:

```bash
terraform output -raw valkey_url_template
# redis://default:<password>@<endpoint>:6379/0
```

Merge it into **three** components' `secrets` blocks: `spi`, `dictHub` and
`dictHubVsync`.

### Three details in that URL are load-bearing

- **`redis://`, not `valkey://`.** Valkey speaks the Redis wire protocol and
  every client library registers the `redis://` scheme. `rediss://` is the TLS
  form — `valkey_url_template` switches to it automatically, and only, when
  `transit_encryption_mode` is `"required"`.
- **`default`** is the Redis 6+ default username. ElastiCache AUTH tokens
  authenticate as this user, so it stays even when no password is set.
- **`/0`** is the logical database index. ElastiCache exposes 16 on every node
  and Terraform creates none of them; `redis_db_index` feeds this path segment.
  There is no `REDIS_DB` key here, unlike midaz — the index lives inside the URL.

## No TLS switch outside the scheme, and the token is not enforced

`transit_encryption_mode` stays `"preferred"` and `auth_token_enabled` stays
`false` in every environment, production included.

`"preferred"` means ElastiCache accepts TLS and plaintext alike, which is what
lets the chart's `redis://` example work unchanged. Flipping to `"required"` is
possible — `valkey_url_template` then emits `rediss://` — but it is a coordinated
change: every one of the three components has to take the new URL at the same
time, and there is no CA-bundle key in the chart if the client needs one.

`auth_token_enabled = false` matches. While the connection is plaintext, sending
an AUTH token puts the credential on the wire; and with no token required, the
userinfo section of the URL can be dropped entirely:

```
redis://<endpoint>:6379/0
```

The token **is** generated and written to
`plugin-br-pix-switch-{env}-valkey/auth-token` regardless, so enabling both later
is a tfvars change plus a values change, not a rebuild. Documented in
`envs/prd.tfvars-example`, not forgotten.

## If you do enable the token: it is already URL-safe — FIXED UPSTREAM

The token is interpolated into a URL, so this mattered. `#` truncates it at the
fragment, `%` starts an invalid percent-escape, `?` opens a query string and `:`
breaks the userinfo split — and the failure was not always clean.

`_modules/valkey-elasticache` now generates **32 characters from alphanumerics
plus `-`, and nothing else**. That one-character special set is not laziness: the
ElastiCache AUTH token is governed by an API *allowlist* (`! & # $ ^ < > -`)
rather than a blocklist, and `-` is its only member that is also RFC 3986
unreserved — `_`, `.` and `~` would be rejected by AWS. The old set was both
url-unsafe *and* largely illegal for that API, which had gone unnoticed only
because `auth_token_enabled` defaults to `false`.

This applies to every datastore in this product, because every one of them is
reached through a URL. See [`../README.md`](../README.md), *The generated
passwords are URL-safe — FIXED UPSTREAM*, and
[`_modules/valkey-elasticache/README.md`](../../../_modules/valkey-elasticache/README.md)
for the allowlist detail.

## Availability

`multi_az_enabled` requires **both** `num_cache_clusters >= 2` **and**
`automatic_failover_enabled = true`. Setting one without the others fails the
apply, not the plan.

A single cache cluster (the dev sizing) also means `reader_endpoint` comes back
null — there is no replica to read from.

## Outputs

Seven uniform contract names shared with every other Lerian datastore root —
`mode`, `endpoint`, `port`, `security_group_id`, `secret_arn`, `secret_name`,
`identifier` — plus `reader_endpoint`, `engine_version_actual`,
`auth_token_enabled`, `transit_encryption_enabled`, `subnet_group_name`, the
cross-stack context, `helm_values` (empty) and `valkey_url_template`.

`endpoint` is the raw ElastiCache primary endpoint in both modes. There is no
`dns_name`: with transit encryption on, the certificate only covers
`*.{cluster}.{region}.cache.amazonaws.com`, so an alias in front of the primary
endpoint fails TLS hostname verification — and this module ships
`transit_encryption_enabled = true` in every environment.

`endpoint` and `port` are exported separately; `valkey_url_template` is the
combined form the chart actually consumes.

## Shared mode

`mode = "shared"` creates nothing and plans to zero resources. Every lookup is
gated on `mode == "dedicated"`. The module resolves the replication group
`shared-{env}-valkey` with `data "aws_elasticache_replication_group"` and the
secret `shared-{env}-valkey/auth-token` with `data "aws_secretsmanager_secret"`,
so `endpoint`, `reader_endpoint` and `port` come from the resolved group.
`security_group_id` comes back `null`.

The name is fully derived, so this root exposes no variable for it. The module's
own `shared_identifier` is the escape hatch for a shared group that is not
called `shared-{env}-valkey`.
