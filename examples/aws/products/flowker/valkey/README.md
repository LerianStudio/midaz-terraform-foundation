# products/flowker/valkey

Valkey (ElastiCache) for flowker. Root stack over
[`_modules/valkey-elasticache`](../../../_modules/valkey-elasticache).

> **The Helm handoff here is EMPTY, and that is deliberate.** flowker has no
> readable chart in this monorepo — `infrastructure/K8S/helm/charts/flowker/`
> contains two vendored tarballs and no `Chart.yaml`. Read
> [`../README.md`](../README.md) first.

One root, one datastore, one state file. Its sibling
[`../documentdb`](../documentdb) is independent.

| | |
|---|---|
| Module | `../../../_modules/valkey-elasticache` |
| State key | `aws/products/flowker/valkey/terraform.tfstate` |
| Creates | `flowker-{env}-valkey` (ElastiCache replication group) |
| Secret | `flowker-{env}-valkey/auth-token` |
| Chart target | **unknown** — `helm_values` is `{}` |

## Run it

```bash
cd examples/aws/products/flowker/valkey

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/flowker/valkey/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

`../../../` is **three** levels up and lands on `examples/aws`. Verified with
`terraform init`.

Prerequisites: `infra-base/vpc`. `infra-base/eks` is optional at apply time.

## Ingress

Performed by
[`_modules/product-network`](../../../_modules/product-network), called here as
`module.network` with `enabled = var.mode == "dedicated"`.

- **`Type=private` subnet CIDRs** (`allow_private_subnet_cidr_ingress`, default
  true) — depends only on `infra-base/vpc`.
- **the EKS node security group**, matched by `tag:Name = "lerian-{env}-eks-node"`
  with the **plural** `data "aws_security_groups"`.

> `var.subnet_tag_type` (`"database"`) selects the subnets the **replication
> group is placed in**. `product-network` keeps its own default (`"private"`),
> the subnets whose CIDRs become **ingress**.

The module already carries `check "ingress_is_reachable"`.

## The empty `helm_values` — and why Redis is the least guessable of all

`outputs.tf` emits `helm_values = {}`. The header of that file carries the full
reasoning. The decisive part is that the Redis variable *shape* is not
recoverable from siblings, because they disagree with each other and one
disagrees with itself:

| Chart | Shape |
|---|---|
| midaz | `REDIS_HOST` carries **`host:port` joined** — `REDIS_PORT` was removed in chart 3.0, and a bare hostname makes the client dial port 0 |
| midaz | `MULTI_TENANT_REDIS_HOST` / `MULTI_TENANT_REDIS_PORT` are **split**, in the same file |
| plugin-fees | only the split `MULTI_TENANT_REDIS_*` form, and only when `MULTI_TENANT_ENABLED` is `"true"` |
| product-console | no Redis variable at all |

Picking a shape here would be a coin flip whose losing side is a silent
connection failure. Use the ordinary outputs instead:

```bash
terraform output endpoint port transit_encryption_required secret_name
```

Join `endpoint` and `port` for a chart that wants `host:port`; use them
separately for one that splits them.

When flowker's chart lands in this monorepo, fill `helm_values` in from **its**
`values.yaml` — never from a sibling's.

## Security posture, and why it is conservative

`transit_encryption_mode` stays `"preferred"` — which accepts TLS and plaintext
clients alike — and `auth_token_enabled` stays `false`.

Everywhere else in this repository that posture has a *named* justification: a
specific chart lacks a TLS/AUTH client configuration. Here there is no chart to
name, so neither can be confirmed. `"required"` or an enforced token against a
client nobody can inspect produces a lockout that looks like a network fault.

**The auth token is generated and stored regardless**, at
`flowker-{env}-valkey/auth-token`. Turning both on later is a tfvars change plus
a chart change, not a rebuild. Until then the cache is protected by the security
group and the private subnets alone — documented, not forgotten.

The dedicated `transit_encryption_required` output exists so that whoever wires
the chart reports *required*, not *available*: those are different questions, and
conflating them flips a plaintext client into a TLS handshake it has no CA
configuration for.

## An open question worth answering before production

**Is Valkey used for distributed locks, or only for caching?** If locks, node
count and failover behaviour stop being a performance question and become a
correctness one. That is exactly what the missing chart would have told us. See
`envs/prd.tfvars-example`.

## Sizing

| Environment | Shape |
|---|---|
| dev | `cache.t4g.micro`, 1 cache cluster (~USD 12/month). No failover, no Multi-AZ, `reader_endpoint` null |
| stg | `cache.t4g.small`, 2 clusters, Multi-AZ — the smallest topology that exercises a real promotion |
| prd | `cache.m7g.large`, 3 clusters, Multi-AZ, 7-day snapshots |

`multi_az_enabled` requires **both** `num_cache_clusters >= 2` **and**
`automatic_failover_enabled = true`. Setting one without the others fails the
apply, not the plan.

## Outputs

Seven uniform contract names — `mode`, `endpoint`, `port`, `security_group_id`,
`secret_arn`, `secret_name`, `identifier` — plus `reader_endpoint`,
`engine_version_actual`, `auth_token_enabled`, `transit_encryption_enabled`,
`transit_encryption_required`, `subnet_group_name`, the cross-stack context
(`vpc_name`, `eks_cluster_name`, `ingress_*`), and the empty `helm_values`.

All of them are correct: the missing chart affects the *handoff*, not the
infrastructure.

`endpoint` is the raw ElastiCache primary endpoint. There is no `dns_name` and no
private zone: with transit encryption on, the certificate only covers
`*.{cluster}.{region}.cache.amazonaws.com`, so an alias in front of it would
break hostname verification.

No password is ever an output.

## Shared mode

`mode = "shared"` creates nothing and plans to zero resources. The module
resolves `shared-{env}-valkey` with
`data "aws_elasticache_replication_group"` and the secret
`shared-{env}-valkey/auth-token`. `security_group_id` comes back `null`: opening
the shared group is `products/shared-resources/valkey`' job.

Every sizing variable in the tfvars is ignored in that mode.
