# products/plugin-br-pix-indirect-btg/valkey

Cache and locks for `pix`, `outbound` and `reconciliation`. Root stack over
[`_modules/valkey-elasticache`](../../../_modules/valkey-elasticache).

One root, one datastore, one state file. See [`../README.md`](../README.md) for
the product-level picture.

| | |
|---|---|
| Module | `../../../_modules/valkey-elasticache` |
| State key | `aws/products/plugin-br-pix-indirect-btg/valkey/terraform.tfstate` |
| Creates | `plugin-br-pix-indirect-btg-{env}-valkey` (ElastiCache replication group) |
| Secret | `plugin-br-pix-indirect-btg-{env}-valkey/auth-token` |
| Chart target | `pix.configmap`, `outbound.configmap`, `reconciliation.configmap` |

`inbound` and `schedule` carry no `REDIS_` key at all and are absent from
`helm_values`.

## Run it

```bash
cd examples/aws/products/plugin-br-pix-indirect-btg/valkey

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/plugin-br-pix-indirect-btg/valkey/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

## TWO SHAPES OF `REDIS_HOST`, IN ONE CHART

This is the thing to get right in this directory, and it is not the usual
chart-versus-chart difference — it is component-versus-component **inside the
same chart**.

| Component | `REDIS_HOST` | `REDIS_PORT` |
|---|---|---|
| `pix` | bare hostname | separate key |
| `outbound` | bare hostname | separate key |
| `reconciliation` | **`host:port`** | **no such key** |

Straight from the templates:

```gotemplate
{{/* templates/pix/configmap.yaml and templates/outbound/configmap.yaml */}}
REDIS_HOST: {{ ... | default (include "...valkeyHost" .) | quote }}
REDIS_PORT: {{ ... | default "6379" | quote }}

{{/* templates/reconciliation/configmap.yaml */}}
REDIS_HOST: {{ ... | default (printf "%s:6379" (include "...valkeyHost" .)) | quote }}
{{/* no REDIS_PORT key */}}
```

`helm_values` emits both shapes, one per component, which is why it is a map of
component → env map rather than a flat map. Copying one entry over the other
breaks it.

Reported as a chart finding in the product README.

## `REDIS_TLS` reports "required", not "available"

`transit_encryption_mode = "preferred"` means ElastiCache accepts TLS and
plaintext clients alike, and the plugin currently connects in plaintext.
Reporting `"true"` there would flip it to a handshake it has no CA configuration
for, so only `"required"` reports `"true"`.

## The known gap: TLS and AUTH are both off, on purpose

`transit_encryption_mode` stays `preferred` and `auth_token_enabled` stays
`false` in every environment, including prd:

- `REDIS_CA_CERT` defaults to empty on all three components and nothing
  distributes the ElastiCache CA bundle into the pod.
- `REDIS_PASSWORD` is operator-provided and empty by default — `_helpers.tpl`
  says so in as many words: *"REDIS_PASSWORD stays operator-provided"*. No
  component sends AUTH before the first command on a plaintext connection.

The auth token **is** generated and stored at
`plugin-br-pix-indirect-btg-{env}-valkey/auth-token` regardless, so flipping both
switches later is a tfvars change plus a chart change, not a rebuild.

## What is not emitted

- **`REDIS_USER`** — the chart defaults it to `"plugin"` on all three components,
  but this repository creates no ElastiCache RBAC user and the implicit
  ElastiCache account is `default`.
  > **CONFIRMAR no chart:** whether the plugin sends `REDIS_USER` at all against
  > an auth-token (non-RBAC) ElastiCache, and what it should be. Guessing
  > `default` would be inventing a value; leaving the chart default in place is
  > the honest state.
- **`REDIS_USE_GCP_IAM`, `REDIS_SERVICE_ACCOUNT`, `REDIS_TOKEN_LIFETIME`,
  `REDIS_TOKEN_REFRESH_DURATION`** — Google Memorystore IAM authentication. This
  is an AWS stack; the chart's `false` / empty defaults are correct here.
- **`REDIS_MASTER_NAME`** — a Sentinel construct. ElastiCache replication groups
  expose no Sentinel.
- **`REDIS_PASSWORD`** — read from `secret_name` by External Secrets.

## The bundled subchart is valkey.io, not Bitnami

Worth knowing when reading the templates: the chart carries its own
`valkeyHost` helper because valkey.io's fullname collapses differently from
Bitnami's and emits a single Service with no `-master`/`-primary` split. It is
also the reason `valkey.enabled: false` is the only switch — there is no
`external:` flag on any subchart in this chart.

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
`subnet_group_name`, the four cross-stack context outputs, and `helm_values`
(keyed by component).
