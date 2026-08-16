# products/midaz/valkey

Cache and distributed locks for the midaz ledger. Root stack over
[`_modules/valkey-elasticache`](../../../_modules/valkey-elasticache).

One root, one datastore, one state file. See [`../README.md`](../README.md) for
the product-level picture: deploy order, the shared-vs-dedicated model, and the
full Helm mapping.

| | |
|---|---|
| Module | `../../../_modules/valkey-elasticache` |
| State key | `aws/products/midaz/valkey/terraform.tfstate` |
| Creates | `midaz-{env}-valkey` (ElastiCache replication group) |
| Secret | `midaz-{env}-valkey/auth-token` |
| Chart target | `ledger.configmap` (`REDIS_*`) |

The CRM deployment has no Redis variables at all.

## Run it

```bash
cd examples/aws/products/midaz/valkey

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/midaz/valkey/terraform.tfstate"

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
   Note the `lerian` prefix on both: they belong to `infra-base`, not to midaz.
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

## `REDIS_HOST` carries `host:port`

This is the one place where copying `endpoint` straight into the chart produces a
broken release.

The midaz chart **removed `REDIS_PORT` in chart 3.0** and requires the port to be
embedded in `REDIS_HOST` as `<host>:<port>`. `helm_values` therefore emits
`"${endpoint}:6379"`, not a bare hostname. A bare hostname produces a ledger that
dials port 0.

The multi-tenant pair is the exception and stays split:
`MULTI_TENANT_REDIS_HOST` and `MULTI_TENANT_REDIS_PORT`. Those two are only
rendered when `MULTI_TENANT_ENABLED` is `"true"`; they are emitted regardless so
enabling multi-tenancy needs no second lookup.

`REDIS_USER` / `REDIS_USERNAME` do not exist in the chart, in any form — even
though the bundled subchart sets `valkey.auth.username`.

## `REDIS_TLS` reports *required*, not *available*

`transit_encryption_enabled` is `true` in every environment, but
`transit_encryption_mode` is `"preferred"` — ElastiCache then accepts TLS and
plaintext clients alike, and the midaz chart connects in plaintext.

Reporting `REDIS_TLS = "true"` in that state would flip the ledger to a TLS
handshake it has no CA configuration for. So `helm_values` only reports `"true"`
when the mode is `"required"`.

Flipping the mode to `"required"` without a corresponding chart change locks the
ledger out.

## The auth token exists but is not enforced

`auth_token_enabled` is `false` in every environment, including production. This
is a **documented gap**, spelled out in `envs/prd.tfvars-example`, not an
oversight:

- `REDIS_CA_CERT` exists in the chart but nothing distributes the ElastiCache CA
  bundle into the pod.
- `REDIS_PASSWORD` is read from a Secret, but the ledger has no code path that
  sends `AUTH` before the first command on a plaintext connection.

The token **is** generated and written to `midaz-{env}-valkey/auth-token`
regardless, so flipping both switches later is a tfvars change plus a chart
change, not a rebuild. Until then the cache is protected by the security group
and the private subnets alone.

## Availability

`multi_az_enabled` requires **both** `num_cache_clusters >= 2` **and**
`automatic_failover_enabled = true`. Setting one without the others fails the
apply, not the plan.

A single cache cluster (the dev sizing) also means `reader_endpoint` comes back
null — there is no replica to read from.

## `REDIS_DB` is not an AWS setting

`redis_db_index` is a stack variable, not an ElastiCache one: every Valkey node
exposes 16 logical databases and Terraform creates none of them. It lives here
so the chart wiring is complete in one place rather than split between Terraform
output and hand-edited values.

## Outputs

Seven uniform contract names shared with every other Lerian datastore root —
`mode`, `endpoint`, `port`, `security_group_id`, `secret_arn`, `secret_name`,
`identifier` — plus `reader_endpoint`, `engine_version_actual`,
`auth_token_enabled`, `transit_encryption_enabled`, `subnet_group_name`, the
cross-stack context, and `helm_values`.

`endpoint` is the raw ElastiCache primary endpoint in both modes. There is no
`dns_name`: with transit encryption on, the certificate only covers
`*.{cluster}.{region}.cache.amazonaws.com`, so an alias in front of the primary
endpoint fails TLS hostname verification — and this module ships
`transit_encryption_enabled = true` in every environment.

`endpoint` and `port` are exported separately as well as combined, because the
`MULTI_TENANT_*` variables need them split.

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
