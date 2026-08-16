# products/tracer

AWS datastores for **tracer** — real-time transaction validation and fraud
prevention, sitting in front of the ledger.

```
examples/aws/products/tracer/
├── postgres/     -> _modules/postgres-rds         tracer-{env}-postgres
└── valkey/       -> _modules/valkey-elasticache   tracer-{env}-valkey   (OPT-IN)
```

See [`../midaz/README.md`](../midaz/README.md) for the parts that are identical
across every product: the `lerian-` / `shared-` prefix split, the `module.network`
lookup, the absence of a private DNS layer, and why `endpoint` is always the raw
AWS host. This README covers only what is specific to tracer.

---

## Why these two

`infrastructure/IAC/product-infra-dependencies.yaml` records:

```yaml
tracer:
  postgresql: yes
  mongodb:    no
  valkey:     no    # opcional, so multi-tenant (MULTI_TENANT_REDIS_HOST)
  rabbitmq:   no
  redpanda:   no
```

Reading the chart confirms it, with one correction and one addition worth
knowing.

**Confirmed.** No MongoDB, no RabbitMQ, no Kafka/Redpanda, no S3. A grep for
`RABBITMQ|AMQP|KAFKA|BROKER|MONGO|STREAMING|S3|BUCKET` across the entire chart
returns **zero** matches — not a comment, not a values key, not a template.
That is why there is no `documentdb/`, `rabbitmq/` or `msk/` directory here.

**Correction to the YAML's shape, not its verdict.** `valkey: no` reads as "no
Valkey". The truthful version is "no Valkey **on the default path**": the chart
does consume a cache, but only for the multi-tenant connection-pool registry,
and only when `MULTI_TENANT_ENABLED` is `"true"`. The `valkey/` root exists so
that switch has infrastructure behind it, and is **opt-in by directory** — see
below.

**Addition.** The tracer chart declares **no `dependencies:` block at all**
(`Chart.yaml`, verified: no such key exists). So unlike midaz there is no
bundled `postgresql` or `valkey` subchart, and consequently **no
`postgresql.enabled: false` to set**. The chart has always expected external
datastores.

That is not the relief it sounds like. The chart still ships an in-cluster
default host:

```yaml
# values.yaml:202
DB_HOST: "tracer-postgresql.tracer.svc.cluster.local."
```

Nothing in the chart creates that Service. Leaving `DB_HOST` unset does not
produce an error — it produces a release aimed at a hostname that does not
resolve, or worse, at a hand-rolled Postgres someone left in the namespace.
Wiring `helm_values` is therefore mandatory, not optional.

## Valkey is opt-in by directory

`products/tracer/valkey` follows the same rule as
`products/shared-resources/*`: **applying the directory is what enables it.**
There is no `valkey_enabled` toggle anywhere.

The chart renders every `MULTI_TENANT_REDIS_*` key inside a single conditional
branch (`templates/configmap.yaml:58-77`, gated on `MULTI_TENANT_ENABLED ==
"true"`). With multi-tenancy off, the cache has no consumer at all. Applying the
directory anyway buys roughly **USD 12/month** of idle ElastiCache in dev, and
considerably more in production.

So:

| Multi-tenancy | What to do |
|---|---|
| off (the default) | apply `postgres/` only. Do not apply `valkey/`. |
| on | apply both, and set `MULTI_TENANT_ENABLED = "true"` plus `MULTI_TENANT_URL` in values — the latter is `required(...)` in the template and fails the render when empty. |

`mode = "shared"` on the valkey root is the middle path: the registry gets a
cache without tracer paying for a dedicated one.

## Helm handoff

| Root | Chart target | Keys |
|---|---|---|
| postgres | `tracer.configmap` | `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER` |
| valkey | `tracer.configmap` | `MULTI_TENANT_REDIS_HOST`, `MULTI_TENANT_REDIS_PORT`, `MULTI_TENANT_REDIS_TLS` |

Verified against chart **tracer-helm 2.1.0** (appVersion 1.0.0),
`templates/configmap.yaml` and `values.yaml`.

```bash
cd examples/aws/products/tracer/postgres
terraform output -json helm_values | jq
```

### These are not the midaz names

tracer uses the short, unsuffixed `DB_*` family. midaz uses `DB_ONBOARDING_*`
and `DB_TRANSACTION_*` and has **no plain `DB_HOST`** on its application
containers at all. Copying either block into the other yields a release that
silently keeps the chart defaults.

### The Redis shape is the *opposite* of midaz

This is the trap the brief warned about, and tracer lands on the other side of
it:

| Chart | `*_REDIS_HOST` | `*_REDIS_PORT` |
|---|---|---|
| midaz | `"host:port"` in one string | **does not exist** (deleted in chart 3.0) |
| **tracer** | **bare hostname** | **exists**, separate key |

`templates/configmap.yaml:62-63` renders the two independently, and
`values.yaml:245-248` documents them as separate values. Concatenating here
produces a registry dialling a hostname with a colon in it.

There is **no plain `REDIS_HOST` / `REDIS_PORT` / `REDIS_TLS` / `REDIS_DB`** in
this chart, in any form. Do not add them.

### Not emitted, on purpose

| Key | Why |
|---|---|
| `DB_PASSWORD` | read from `secret_name` by External Secrets. It is `tracer.secrets.DB_PASSWORD` (`values.yaml:275`). |
| `MULTI_TENANT_REDIS_PASSWORD` | same, and optional — `templates/secrets.yaml:6` says so explicitly. |
| `DB_SSL_MODE` | client policy, not an infrastructure fact. Same call the midaz root makes about its `DB_*_SSLMODE`. Chart default `"disable"`. |
| `MIGRATIONS_PATH` | an application path. |
| `MULTI_TENANT_URL`, `MULTI_TENANT_SERVICE_API_KEY`, the pool and circuit-breaker tuning keys | application configuration and a control-plane URL; the datastore knows nothing about them. |

### The optional bootstrap Job

The chart ships `templates/bootstrap-postgres.yaml`, off by default
(`values.yaml:12`), which creates the `tracer` database and role on an external
instance using an **admin** login (`global.externalPostgresDefinitions.*`).

It is deliberately **not** wired from `helm_values`. Its `connection.host` and
`connection.port` take the same `endpoint` and `port` as above, but its
`postgresAdminLogin` needs the RDS **master** credentials — and handing a
Kubernetes Job the master password is a decision for whoever operates the
cluster, not a Terraform default.

> Note for whoever reads `docs/UPGRADE-2.1.md`: it refers to
> `global.postgresql.adminCredentials.*` / `global.postgresql.tracerCredentials.*`,
> paths that **do not exist** in the current `values.yaml`, which uses
> `global.externalPostgresDefinitions.postgresAdminLogin` /
> `.tracerCredentials`. The upgrade doc is stale. Trust `values.yaml`.

## Security posture

`auth_token_enabled = false` and `transit_encryption_mode = "preferred"` in all
three environments, as everywhere else in this repository — but the gap here is
**smaller than midaz's**, and worth closing sooner.

Unlike the midaz chart, tracer ships both client-side knobs:

- `MULTI_TENANT_REDIS_TLS` (`values.yaml:251`), which the chart in fact defaults
  to `"true"`;
- `MULTI_TENANT_REDIS_PASSWORD`, an optional chart secret
  (`templates/secrets.yaml:6`).

So flipping `transit_encryption_mode` to `"required"` and `auth_token_enabled`
to `true` is a tfvars change plus a values change, with **no chart change
needed** — which is exactly what blocks midaz. Rehearse it in stg first: the
token is generated and stored at `tracer-{env}-valkey/auth-token` regardless of
the switch, so nothing has to be rebuilt.

Note the disagreement while it lasts: the chart defaults `MULTI_TENANT_REDIS_TLS`
to `"true"` and this stack reports `"false"` (because `"preferred"` means TLS is
*available*, not *required*). The Terraform value describes what the server
enforces and is the one to wire.

## Deploy order

```
1. examples/aws/bootstrap
2. examples/aws/infra-base/vpc            -> lerian-{env}-vpc
3. examples/aws/infra-base/eks            -> lerian-{env}-eks
4. examples/aws/products/shared-resources/*   (OPTIONAL, only for mode = "shared")
5. products/tracer/postgres  [+ products/tracer/valkey if multi-tenant]
6. helm upgrade --install tracer ...
```

Step 2 is the one hard prerequisite. Step 3 is not — the EKS node security group
is resolved with the **plural** `data "aws_security_groups"`, which returns an
empty list instead of failing, and `check "eks_node_security_group_resolved"`
warns until the cluster exists. The two roots in step 5 have no dependency on
each other.

## Running a stack

```bash
cd examples/aws/products/tracer/postgres

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/tracer/postgres/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

| Stack | State key |
|---|---|
| postgres | `aws/products/tracer/postgres/terraform.tfstate` |
| valkey | `aws/products/tracer/valkey/terraform.tfstate` |

`*.tfvars` is gitignored; `*.tfvars-example` is not. Copy, then edit.

## What gets created

`mode = "dedicated"`, `environment = "dev"`:

| Stack | AWS resource | Secrets Manager | ~USD/month |
|---|---|---|---|
| postgres | `tracer-dev-postgres` (RDS `db.t4g.micro`, 20 GB) | `tracer-dev-postgres/password` | 15 |
| valkey | `tracer-dev-valkey` (ElastiCache `cache.t4g.micro`, 1 node) | `tracer-dev-valkey/auth-token` | 12 |

Postgres only: **~USD 15/month**. With the opt-in cache: **~USD 27/month**.
Estimates — price them against your own AWS Pricing Calculator.
