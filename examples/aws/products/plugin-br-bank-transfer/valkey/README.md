# products/plugin-br-bank-transfer/valkey

Idempotency keys, distributed locks and the rate limiter. Root stack over
[`_modules/valkey-elasticache`](../../../_modules/valkey-elasticache).

One root, one datastore, one state file. See [`../README.md`](../README.md) for
the product-level picture.

| | |
|---|---|
| Module | `../../../_modules/valkey-elasticache` |
| State key | `aws/products/plugin-br-bank-transfer/valkey/terraform.tfstate` |
| Creates | `plugin-br-bank-transfer-{env}-valkey` (ElastiCache replication group) |
| Secret | `plugin-br-bank-transfer-{env}-valkey/auth-token` |
| Chart target | `bankTransfer.configmap` (`REDIS_*`, `MULTI_TENANT_REDIS_*`) |

## Run it

```bash
cd examples/aws/products/plugin-br-bank-transfer/valkey

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/plugin-br-bank-transfer/valkey/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

## `REDIS_HOST` carries `host:port`

There is no `REDIS_PORT` key in this chart. The evidence is stronger than a
default value — the init container in `templates/deployment.yaml` splits the
variable itself before probing:

```sh
REDIS_SVC=$(echo "$REDIS_HOST" | cut -d: -f1)
REDIS_PORT_NUM=$(echo "$REDIS_HOST" | cut -d: -f2)
wait_for_service "$REDIS_SVC" "$REDIS_PORT_NUM"
```

Emit a bare hostname and that `cut` returns the hostname twice: the readiness
gate dials the host as if it were a port number, and the pod never becomes
ready.

| Chart | `REDIS_HOST` | `REDIS_PORT` |
|---|---|---|
| plugin-br-bank-transfer 1.5.0 | `host:port` inline | does not exist |
| midaz 8.7.0 | `host:port` inline | removed in chart 3.0 |
| notifications 1.0.0-beta.4 | bare hostname | exists, separate key |

Two out of three is not a convention. Read the chart.

The `MULTI_TENANT_REDIS_HOST` / `MULTI_TENANT_REDIS_PORT` pair **is** split —
the shape flips inside this one ConfigMap.

## Rendered in both tenancy modes

Unlike `POSTGRES_*` and `MONGO_*`, which the chart hides behind
`{{- if not $multiTenantEnabled }}`, the connection half of the Redis block is
rendered either way. Only the pool and timeout tuning is single-tenant.

- single-tenant: `REDIS_HOST`, `REDIS_DB`, `REDIS_TLS` are read
- multi-tenant: those are still read, **plus** `MULTI_TENANT_REDIS_HOST`
  (which the chart marks `required()`), `MULTI_TENANT_REDIS_PORT` and
  `MULTI_TENANT_REDIS_TLS`

`helm_values` emits all six so enabling multi-tenancy needs no second lookup.

## `REDIS_TLS` reports "required", not "available"

`transit_encryption_mode = "preferred"` means ElastiCache accepts TLS and
plaintext clients alike, and the plugin currently connects in plaintext.
Reporting `"true"` there would flip it to a handshake it has no CA configuration
for, so only `"required"` reports `"true"`.

## The known gap: TLS and AUTH are both off, on purpose

`transit_encryption_mode` stays `preferred` and `auth_token_enabled` stays
`false` in every environment, including prd:

- `REDIS_CA_CERT` is rendered only when the operator sets it, and nothing
  distributes the ElastiCache CA bundle into the pod.
- `REDIS_PASSWORD` is read from a Secret, but the plugin has no code path that
  sends AUTH before the first command on a plaintext connection.

The auth token **is** generated and stored at
`plugin-br-bank-transfer-{env}-valkey/auth-token` regardless, so flipping both
switches later is a tfvars change plus a chart change, not a rebuild. Until then
the cache is protected by the security group and the private subnets alone.
Documented in `envs/prd.tfvars-example`, not forgotten.

## `REDIS_USER` is not emitted

> **CONFIRMAR no chart.** The chart renders `REDIS_USER` only when the operator
> sets it, and this repository configures no ElastiCache RBAC user. The implicit
> ElastiCache account is `default`, but whether the plugin needs `REDIS_USER` at
> all against an auth-token (non-RBAC) ElastiCache is a question for the plugin
> team. Guessing `default` here would be inventing a value.

`REDIS_MASTER_NAME` is not emitted either — it is a Sentinel construct, and
ElastiCache replication groups expose no Sentinel.

## Both subchart switches

```yaml
valkey:
  enabled:  false
  external: true
```

`templates/deployment.yaml` chooses where `REDIS_PASSWORD` comes from based on
`valkey.enabled`, `valkey.external` **and** `valkey.auth.enabled` together.
`external: true` is what moves it onto the chart's own Secret.

## Sizing

| Env | Node type | Clusters |
|---|---|---|
| dev | `cache.t4g.micro` | 1 (~USD 12/month, no failover, empty `reader_endpoint`) |
| stg | `cache.t4g.small` | 2, Multi-AZ |
| prd | `cache.m7g.large` | 3, Multi-AZ, 7-day snapshots |

`multi_az_enabled` requires **both** `num_cache_clusters >= 2` **and**
`automatic_failover_enabled = true`.

## Outputs

The seven uniform contract names, plus `reader_endpoint`,
`engine_version_actual`, `auth_token_enabled`, `transit_encryption_enabled`,
`subnet_group_name`, the four cross-stack context outputs, and `helm_values`.
