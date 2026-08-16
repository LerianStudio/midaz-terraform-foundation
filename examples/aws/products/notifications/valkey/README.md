# products/notifications/valkey

Cache, idempotency store, destination-auth cache and rate limiter for the
notifications service. Root stack over
[`_modules/valkey-elasticache`](../../../_modules/valkey-elasticache).

One root, one datastore, one state file. See [`../README.md`](../README.md) for
the product-level picture.

| | |
|---|---|
| Module | `../../../_modules/valkey-elasticache` |
| State key | `aws/products/notifications/valkey/terraform.tfstate` |
| Creates | `notifications-{env}-valkey` (ElastiCache replication group) |
| Secret | `notifications-{env}-valkey/auth-token` |
| Chart target | `.Values.config` (`REDIS_*`, `MULTI_TENANT_REDIS_*`) and `.Values.secrets` (`REDIS_TLS`) |

## Run it

```bash
cd examples/aws/products/notifications/valkey

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/notifications/valkey/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

## `REDIS_HOST` is a bare hostname — the midaz trap in reverse

This is the one thing to get right, and it is the opposite of what
[`products/midaz/valkey`](../../midaz/valkey) does.

| Chart | `REDIS_HOST` | `REDIS_PORT` |
|---|---|---|
| notifications 1.0.0-beta.4 | bare hostname | exists, separate key |
| midaz 8.7.0 | `host:port` inline | **removed in chart 3.0** |

Evidence, from this chart: `values.yaml` declares both `REDIS_HOST: ""` and
`REDIS_PORT: "6379"` under `config`, and the chart README describes
`config.REDIS_HOST` as "External Redis host". Emitting `host:6379` here produces
a hostname with a colon in it and resolves to nothing.

The `MULTI_TENANT_REDIS_HOST` / `MULTI_TENANT_REDIS_PORT` pair is split on both
charts, so that half copies cleanly.

## `REDIS_TLS` reports "required", not "available"

`transit_encryption_mode = "preferred"` means ElastiCache accepts TLS and
plaintext clients alike, and the chart currently connects in plaintext.
Reporting `"true"` in that state would flip the service to a TLS handshake it
has no CA configuration for, so only `"required"` reports `"true"`.

The flag lives in `.Values.secrets`, not `.Values.config` — it is not a
credential, the chart just keeps it next to `REDIS_PASSWORD` and
`REDIS_CA_CERT`. That is why this root exports `helm_secret_values` alongside
`helm_values`.

## The known gap: TLS and AUTH are both off, on purpose

`transit_encryption_mode` stays `preferred` and `auth_token_enabled` stays
`false` in every environment — including prd. Not because production should run
a plaintext unauthenticated cache, but because the chart is not wired for
either:

- `REDIS_CA_CERT` exists in `.Values.secrets` but nothing distributes the
  ElastiCache CA bundle into the pod.
- `REDIS_PASSWORD` exists but ships empty, and no component sends AUTH before
  the first command on a plaintext connection.

The auth token **is** generated and stored at
`notifications-{env}-valkey/auth-token` regardless, so flipping both switches
later is a tfvars change plus a chart change, not a rebuild. Until then the
cache is protected by the security group and the private subnets alone.
Documented in `envs/prd.tfvars-example`, not forgotten.

## `REDIS_MASTER_NAME` is not emitted

It is a Sentinel construct. ElastiCache replication groups expose no Sentinel
endpoint, so there is no value to put there; the chart's empty default is
correct.

## Sizing

| Env | Node type | Clusters | Notes |
|---|---|---|---|
| dev | `cache.t4g.micro` | 1 | ~USD 12/month. No failover, no Multi-AZ, `reader_endpoint` empty |
| stg | `cache.t4g.small` | 2 | smallest topology that exercises a promotion |
| prd | `cache.m7g.large` | 3 | Multi-AZ, snapshots retained 7 days |

`multi_az_enabled` requires **both** `num_cache_clusters >= 2` **and**
`automatic_failover_enabled = true`. Setting one without the others fails the
apply, not the plan.

## No subchart to switch off

The chart bundles no Valkey. `notifications/Chart.yaml` declares no dependencies
at all, so there is nothing to disable alongside ElastiCache.

## Outputs

The seven uniform contract names, plus `reader_endpoint`,
`engine_version_actual`, `auth_token_enabled`, `transit_encryption_enabled`,
`subnet_group_name`, the four cross-stack context outputs, `helm_values` and
`helm_secret_values`.
