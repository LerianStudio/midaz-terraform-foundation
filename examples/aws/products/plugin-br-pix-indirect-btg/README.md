# products/plugin-br-pix-indirect-btg

AWS datastores for the **plugin-br-pix-indirect-btg** product: Pix indirect
participation through BTG.

Three independent root stacks, one per datastore:

```
examples/aws/products/plugin-br-pix-indirect-btg/
├── postgres/     -> _modules/postgres-rds         plugin-br-pix-indirect-btg-{env}-postgres
├── documentdb/   -> _modules/mongodb-documentdb   plugin-br-pix-indirect-btg-{env}-docdb
└── valkey/       -> _modules/valkey-elasticache   plugin-br-pix-indirect-btg-{env}-valkey
```

**There is no broker.** `Chart.yaml` declares exactly three dependencies —
postgresql, valkey, mongodb — and no `RABBITMQ_` key appears anywhere in the
chart's templates. The discovery YAML's `rabbitmq: no` is confirmed.

The directory name is the chart name, `plugin-` prefix included. Everything
structural — the `lerian-{env}-vpc` / `lerian-{env}-eks` derivations, the
`shared-{env}-*` resolution of the shared tier, the ingress model, the `check`
block, the provider and backend blocks — is identical to
[`products/midaz`](../midaz/README.md) and is not re-explained here.

---

## Why these three

From the chart discovery in `infrastructure/IAC/product-infra-dependencies.yaml`:

```yaml
plugin-br-pix-indirect-btg:
  postgresql: yes
  mongodb:    yes
  valkey:     yes
  rabbitmq:   no
  redpanda:   no
```

Confirmed against `Chart.yaml`:

| Chart dependency | Version | Repository | Default | Turn off with |
|---|---|---|---|---|
| `postgresql` | 16.3.5 | charts.bitnami.com/bitnami | `enabled: true` | `postgresql.enabled: false` |
| `valkey` | 0.7.4 | **valkey.io/valkey-helm** | `enabled: true` | `valkey.enabled: false` |
| `mongodb` | 16.4.0 | charts.bitnami.com/bitnami | `enabled: true` | `mongodb.enabled: false` |

> The Valkey subchart here is **valkey.io**, not Bitnami — different from every
> other Lerian chart. The chart notes why it matters: valkey.io's fullname helper
> collapses differently and emits a single Service with no `-master`/`-primary`
> split, which is why the chart carries its own `valkeyHost` helper instead of
> reusing the Bitnami one. Irrelevant once the subchart is off, but it explains
> the shape of the templates.

Unlike `plugin-br-bank-transfer`, this chart has **no `external:` flag** on any
subchart. `enabled: false` is the whole switch; credential resolution keys off
the same `enabled` value (`postgresInternal` / `mongoInternal` /
`valkeyInternal` in `_helpers.tpl`).

---

## Five components, five ConfigMaps, five different env shapes

This is the fact that shapes every output in this directory.

| Component | Postgres | Redis | Mongo | Notes |
|---|---|---|---|---|
| `pix` | yes | yes (split) | yes + `MONGO_TLS` | the only component with `MONGO_TLS` |
| `inbound` | yes | **no** | yes | no Redis keys at all |
| `outbound` | yes | yes (split) | yes | |
| `reconciliation` | yes | yes (**inline**) | **no** | `REDIS_HOST` carries `host:port`, no `REDIS_PORT` key |
| `schedule` | **no** | **no** | **no** | its ConfigMap has no datastore key of any kind |

There is no shared ConfigMap to merge into, so **`helm_values` in each root is a
map of component → env map**, not the flat map the midaz and notifications roots
emit:

```bash
terraform output -json helm_values
# { "pix": {...}, "inbound": {...}, "outbound": {...}, "reconciliation": {...} }
```

Merge each entry into the matching `<component>.configmap` block. Components
absent from a map are absent because that component has no key for that
datastore — not because the value was skipped.

---

## Helm handoff

Verified against chart **3.8.0** (appVersion 1.9.1),
`templates/{pix,inbound,outbound,reconciliation,schedule}/configmap.yaml`,
`templates/*/secrets.yaml`, `templates/bootstrap-mongodb.yaml` and
`templates/_helpers.tpl`.

### postgres → `DB_*` (not `POSTGRES_*`)

| Terraform | Chart key | Components |
|---|---|---|
| `endpoint` | `DB_HOST` | pix, inbound, outbound, reconciliation |
| `port` | `DB_PORT` | all four |
| `username` | `DB_USER` | all four |
| `database_name` | `DB_NAME` | all four |
| `replica_endpoint` (or the primary) | `DB_REPLICA_HOST` | all four |
| `port` / `username` / `database_name` | `DB_REPLICA_PORT` / `_USER` / `_NAME` | all four |
| `secret_name` → External Secrets | `DB_PASSWORD` | all four |

> **Four Lerian charts, three prefixes for the same thing:**
> `DB_HOST` here, `POSTGRES_HOST` in plugin-br-bank-transfer and notifications,
> `DB_ONBOARDING_HOST` / `DB_TRANSACTION_HOST` in midaz.

**`DB_HOST` is `required()` on the external path.** `_helpers.tpl` carries
`dbHostRequired`, which `fail()`s per component with *"`<component>`.configmap.DB_HOST
is REQUIRED when the bundled postgresql subchart is disabled or external"*. The
same helper family `fail()`s when `<component>.secrets.DB_PASSWORD` is unset. So
this output is not a convenience — the release does not render without it.

The replica keys are **always** emitted, pointed at the primary when no replica
exists. That is the chart's own shape (`DB_REPLICA_HOST` defaults to the same
host helper as `DB_HOST`), it matches midaz, and it is the opposite of
`plugin-br-bank-transfer`, whose chart gates the whole replica block on the host
being set. It also matters on the external path: the host helper returns **empty**
when the subchart is off, and only `DB_HOST` has a guard — an unset
`DB_REPLICA_HOST` would silently render as `""`.

`DB_SSL_MODE` is not emitted: client policy, and the chart default `disable` is
accepted by RDS. `REPLICATION_PASSWORD` (in `pix/secrets.yaml`) is a bundled
streaming-replication credential; an RDS read replica does not use it.

### documentdb → `MONGO_*`, split host/port

| Terraform | Chart key | Components |
|---|---|---|
| literal `"mongodb"` | `MONGO_URI` (a **scheme**, not a URI) | pix, inbound, outbound |
| `endpoint` | `MONGO_HOST` | pix, inbound, outbound |
| `port` | `MONGO_PORT` | pix, inbound, outbound |
| `master_username` | `MONGO_USER` | pix, inbound, outbound |
| derived from `documentdb_tls` | `MONGO_TLS` | **pix only** |
| `secret_name` → External Secrets | `MONGO_PASSWORD` | pix, inbound, outbound |

`MONGO_URI` is the scheme alone and the application assembles the connection
string from the surrounding variables — the midaz shape. `mongodb` is the only
correct value for DocumentDB: it publishes no SRV records, so `mongodb+srv`
cannot resolve.

**`MONGO_HOST` is `required()` on the external path**, same helper family as
`DB_HOST`.

Compare with the sibling product: `plugin-br-bank-transfer` is **URI-only** and
takes a single `MONGO_URI` carrying scheme, credentials, host, port and query
parameters. Same company, same quarter, opposite designs. Nothing transfers
between the two.

`MONGO_NAME` is not emitted — DocumentDB creates a database lazily on first
write, so Terraform never creates it and must not claim to know it.

### valkey → two shapes of `REDIS_HOST`, inside one chart

| Component | `REDIS_HOST` | `REDIS_PORT` |
|---|---|---|
| `pix` | bare hostname | yes |
| `outbound` | bare hostname | yes |
| `reconciliation` | **`host:port`** | **no such key** |
| `inbound`, `schedule` | — | — |

Straight from the templates:

```gotemplate
{{/* pix and outbound */}}
REDIS_HOST: {{ ... | default (include "...valkeyHost" .) | quote }}
REDIS_PORT: {{ ... | default "6379" | quote }}

{{/* reconciliation */}}
REDIS_HOST: {{ ... | default (printf "%s:6379" (include "...valkeyHost" .)) | quote }}
{{/* no REDIS_PORT key at all */}}
```

Emitting one shape for all three breaks whichever two it does not match, which
is the other reason `helm_values` here is keyed by component.

`REDIS_DB` and `REDIS_TLS` are the same on all three. `REDIS_TLS` reports
whether TLS is **required**, not whether it is available.

Not emitted:

- `REDIS_USER` — the chart defaults it to `"plugin"` on all three components,
  but this repository creates no ElastiCache RBAC user and the implicit
  ElastiCache account is `default`.
  > **CONFIRMAR no chart:** whether the plugin sends `REDIS_USER` at all against
  > an auth-token (non-RBAC) ElastiCache, and what it should be. Leaving the
  > chart default in place is the honest state.
- `REDIS_USE_GCP_IAM`, `REDIS_SERVICE_ACCOUNT`, `REDIS_TOKEN_LIFETIME`,
  `REDIS_TOKEN_REFRESH_DURATION` — Google Memorystore IAM authentication. This
  is an AWS stack; the chart's `false` / empty defaults are correct here.
- `REDIS_MASTER_NAME` — a Sentinel construct; ElastiCache exposes no Sentinel.

---

## Findings for the chart owners

Recorded here because they were found while reading the chart to build these
roots, and they are not things this stack can fix.

1. **`REDIS_HOST` has two incompatible shapes in one chart.** `pix` and
   `outbound` take host + `REDIS_PORT`; `reconciliation` takes `host:port` and
   has no `REDIS_PORT`. Any operator writing one values file for the release will
   get one of them wrong.
2. **`DB_NAME` disagrees three ways.** `pix`, `inbound` and `outbound` default to
   `pix`; `reconciliation` defaults to `pix_btg`; the bundled `postgresql`
   subchart provisions database `pix_btg` with user `pix_btg`. Against a single
   RDS instance only one database exists, so at most one of those defaults can be
   right.
3. **`DB_USER` disagrees two ways.** All four components default to `plugin`; the
   bundled subchart provisions `pix_btg`. On the bundled path the application
   default cannot authenticate.
4. **`MONGO_USER` disagrees two ways, by punctuation.** The components default to
   `pix-btg` (hyphen); the bundled subchart's `rootUser` is `pix_btg`
   (underscore).
5. **`MONGO_TLS` exists only on `pix`.** `inbound` and `outbound` speak Mongo but
   have no way to be told TLS is on, so "TLS enabled on the cluster" is a state
   the chart cannot fully express.
6. **`templates/bootstrap-mongodb.yaml` may not work against DocumentDB.** It
   runs `mongosh` with `MONGO_ROOT_USER` / `MONGO_ROOT_PASSWORD` and
   creates/updates an application user from `MONGO_APP_USER` /
   `MONGO_APP_PASSWORD` with roles parsed from `ROLES_JSON`, against `admin`.
   DocumentDB implements a restricted subset of MongoDB's role model.
   > **CONFIRMAR com o time:** whether that Job is expected to run against
   > DocumentDB, and whether `ROLES_JSON` uses only roles DocumentDB supports.
   > Terraform creates the master user only.
7. The bundled `postgresql` and `mongodb` subcharts pin image tag `"latest"` with
   `global.security.allowInsecureImages: true`. Not this stack's problem once the
   subcharts are off, but it is the reason the bundled path cannot be pinned.

---

## Deploy order

```
1. examples/aws/bootstrap                (state bucket + lock table, per env)
2. examples/aws/infra-base/vpc           -> lerian-{env}-vpc
3. examples/aws/infra-base/eks           -> lerian-{env}-eks
4. examples/aws/products/shared-resources/*  (OPTIONAL, only for mode = "shared")
5. products/plugin-br-pix-indirect-btg/{postgres,documentdb,valkey}   <- in parallel
6. helm upgrade --install plugin-br-pix-indirect-btg ...
```

State keys:

| Stack | State key |
|---|---|
| postgres | `aws/products/plugin-br-pix-indirect-btg/postgres/terraform.tfstate` |
| documentdb | `aws/products/plugin-br-pix-indirect-btg/documentdb/terraform.tfstate` |
| valkey | `aws/products/plugin-br-pix-indirect-btg/valkey/terraform.tfstate` |

```bash
cd examples/aws/products/plugin-br-pix-indirect-btg/postgres

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/plugin-br-pix-indirect-btg/postgres/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

---

## What gets created

With `mode = "dedicated"` and `environment = "dev"`:

| Stack | AWS resource | Secrets Manager |
|---|---|---|
| postgres | `plugin-br-pix-indirect-btg-dev-postgres` (RDS) | `plugin-br-pix-indirect-btg-dev-postgres/password` |
| documentdb | `plugin-br-pix-indirect-btg-dev-docdb` (DocumentDB) | `plugin-br-pix-indirect-btg-dev-docdb/password` |
| valkey | `plugin-br-pix-indirect-btg-dev-valkey` (ElastiCache) | `plugin-br-pix-indirect-btg-dev-valkey/auth-token` |

---

## Dev cost

Approximate `us-east-1` on-demand, `mode = "dedicated"`, minimum sizing:

| Stack | Sizing | ~USD/month |
|---|---|---|
| postgres | `db.t4g.micro`, 20 GB | 15 |
| valkey | `cache.t4g.micro`, 1 node | 12 |
| documentdb | `db.t3.medium`, 1 instance | 60 |
| **total** | | **~87** |

*Estimates. Price them against your own AWS Pricing Calculator before committing
to a size.*

DocumentDB is two thirds of that and has no cheap corner: `db.t3.medium` is the
smallest class the service offers, the RDS micro/small range does not exist for
it, and the module rejects those values with a plan-time precondition. If a dev
environment cannot carry it, set `mode = "shared"` on the documentdb root and
consume `products/shared-resources/documentdb`.
