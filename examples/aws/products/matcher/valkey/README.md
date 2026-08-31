# products/matcher/valkey

Cache datastore for the Matcher reconciliation service. Root stack over
[`_modules/valkey-elasticache`](../../../_modules/valkey-elasticache).

> **Composition inferred.** The Matcher chart is not in this repository — see the
> "Inferred composition" section of [`../README.md`](../README.md) before wiring
> anything. `helm_values` in this root is empty on purpose.

| | |
|---|---|
| Module | `../../../_modules/valkey-elasticache` |
| State key | `aws/products/matcher/valkey/terraform.tfstate` |
| Creates | `matcher-{env}-valkey` (ElastiCache replication group) |
| Secret | `matcher-{env}-valkey/auth-token` |
| Chart target | **unknown** — no readable chart |

## Run it

```bash
cd examples/aws/products/matcher/valkey

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/matcher/valkey/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

## Why the dependency is believable

`charts/matcher/charts/valkey-2.4.7.tgz` is the Bitnami Valkey chart at the same
version midaz and plugin-br-bank-transfer pin. Solid evidence of a `valkey`
dependency, and nothing more.

## Wiring the release, for now

```bash
terraform output endpoint     # the primary host
terraform output port         # 6379
terraform output secret_name  # -> External Secrets -> the auth token
```

**The host/port shape is the open question.** For orientation only, not a
recommendation to hardcode:

| Chart | Shape |
|---|---|
| midaz | `REDIS_HOST` carries `host:port`, no `REDIS_PORT` |
| plugin-br-bank-transfer | same — `host:port`, no `REDIS_PORT` |
| notifications | bare `REDIS_HOST` plus a separate `REDIS_PORT` |
| plugin-br-pix-indirect-btg | **both**, depending on the component |

There is no Lerian convention to fall back on. This root publishes `endpoint` and
`port` separately; concatenate them only if the chart turns out to want that.

## TLS and AUTH are off, and why

`transit_encryption_mode` stays `preferred` — ElastiCache accepts TLS and
plaintext clients alike — and `auth_token_enabled` stays `false` in every
environment, including prd.

Not a security preference: there is no chart to confirm the Matcher application
is TLS-capable or that it sends AUTH before the first command. Requiring either
from an unknown client is how a deployment fails at connect time rather than at
plan time.

The auth token **is** generated and stored at `matcher-{env}-valkey/auth-token`
regardless, so turning enforcement on later is a one-line tfvars change once the
Matcher team confirms the client behaviour. Until then the cache is protected by
the security group and the private subnets alone.

## Sizing

| Env | Node type | Clusters |
|---|---|---|
| dev | `cache.t4g.micro` | 1 (~USD 12/month, no failover, empty `reader_endpoint`) |
| stg | `cache.t4g.small` | 2, Multi-AZ |
| prd | `cache.m7g.large` | 3, Multi-AZ, 7-day snapshots |

`multi_az_enabled` requires **both** `num_cache_clusters >= 2` **and**
`automatic_failover_enabled = true`. Setting one without the others fails the
apply, not the plan.

There is no `redis_db_index` variable in this root, unlike the other products:
`REDIS_DB` is a chart variable, and there is no chart here to emit it into.

## Outputs

The seven uniform contract names, plus `reader_endpoint`,
`engine_version_actual`, `auth_token_enabled`, `transit_encryption_enabled`,
`subnet_group_name`, the four cross-stack context outputs, and `helm_values` —
which is `{}` and explains itself in the file.
