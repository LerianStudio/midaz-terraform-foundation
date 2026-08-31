# products/plugin-br-pix-switch

AWS datastores for **plugin-br-pix-switch** — the Lerian Pix switch: SPI, DICT
and COB, ten components under one umbrella chart.

Four independent root stacks, one per datastore:

```
examples/aws/products/plugin-br-pix-switch/
├── postgres/     -> _modules/postgres-rds        plugin-br-pix-switch-{env}-postgres
├── documentdb/   -> _modules/mongodb-documentdb  plugin-br-pix-switch-{env}-docdb
├── valkey/       -> _modules/valkey-elasticache  plugin-br-pix-switch-{env}-valkey
└── rabbitmq/     -> _modules/rabbitmq-amazonmq   plugin-br-pix-switch-{env}-rabbitmq
```

Everything structural — the `lerian-{env}-vpc` / `lerian-{env}-eks` derivations,
the `shared-{env}-*` resolution of the shared tier, the ingress model, the
`check` blocks, the provider and backend blocks — is identical to
[`products/midaz`](../midaz/README.md), which is the template.

**The Helm handoff is not, and the difference is structural rather than
cosmetic.** Read the next section before copying any `helm_values` shape from
there.

---

## THE ONE THING TO READ: this chart consumes connection URLs

Every other Lerian chart reads a datastore as **separate ConfigMap keys** —
`DB_HOST`, `DB_PORT`, `DB_USER`. plugin-br-pix-switch reads it as **one
connection URL, in a Secret**:

| Datastore | Chart key | Where | Shape |
|---|---|---|---|
| Postgres | `DATABASE_URL`, `SYSTEMPLANE_POSTGRES_DSN` | `<component>.secrets` × 7 components | `postgres://user:pass@host:5432/db?sslmode=require` |
| Mongo | `MONGO_URL` | `dictHub.secrets` | `mongodb://user:pass@host:27017/?authSource=admin` |
| Valkey | `VALKEY_URL` | `spi.secrets`, `dictHub.secrets`, `dictHubVsync.secrets` | `redis://default:pass@host:6379/0` |
| RabbitMQ | `RABBITMQ_URI` | `dictHubVsync.secrets` | `amqps://user:pass@host:5671/` |

`<component>.configmap` and `<component>.secrets` are emitted **verbatim** into a
ConfigMap and a Secret (`templates/spi/secrets.yaml:13-15`). There is no host
key, no port key and no user key anywhere in the component surface.

### Two consequences

**1. Terraform cannot fill a secret.** A URL carries the password, and this
repository never emits a password — it lives only in Secrets Manager, read by
External Secrets. So each root publishes a **template output** with the password
left as the literal placeholder `<password>`:

```bash
cd examples/aws/products/plugin-br-pix-switch/postgres
terraform output -json database_url_templates | jq       # one per database
terraform output -raw  mongo_url_template                # ../documentdb
terraform output -raw  valkey_url_template               # ../valkey
terraform output -raw  rabbitmq_uri_template             # ../rabbitmq
```

**2. `helm_values` carries Helm value PATHS, not env var names** — where it
carries anything at all. The only non-secret surface the chart exposes is the
connection block of its two **bootstrap Jobs**:

| Root | `helm_values` |
|---|---|
| postgres | `global.externalPostgresDefinitions.connection.host` / `.port`, `…postgresAdminLogin.username` |
| documentdb | `global.externalMongoDefinitions.connection.host` / `.port`, `…mongoAdminLogin.username` |
| valkey | **empty** — no bootstrap Job, so no non-secret surface at all |
| rabbitmq | **empty** — same |

Two empty maps and two maps of value paths is the honest answer for this chart.
It is not incompleteness.

---

## The generated passwords are URL-safe — FIXED UPSTREAM

**This used to be the cross-cutting trap of this product. It is closed.**

This product is the sharpest case in the fleet: every datastore is reached
through a **URL** (`DATABASE_URL`, `MONGO_URL`, `VALKEY_URL`, `RABBITMQ_URI`), so
every generated password is interpolated into one. The shared modules used to
generate characters that break URLs. They no longer do:

| Module | Was | Now | Length |
|---|---|---|---|
| `_modules/postgres-rds` | `!#$%^&*()-_=+[]{}<>:?` — `#` `%` `?` `:` | `-_.~` | 16 → **32** |
| `_modules/mongodb-documentdb` | `!#$^&*()-_=+[]{}<>?` — `#` `$` `?` | `-_.~` | 16 → **32** |
| `_modules/rabbitmq-amazonmq` | `!#$%^&*()-_+{}<>?` — `#` `%` `?` | `-_.~` | 16 → **32** |
| `_modules/valkey-elasticache` | `` !#$%&'()*+,-.:<=>?[]^_`{|}~ `` | **`-`** | 32 |

`-_.~` is the RFC 3986 §2.3 *unreserved* set: no percent-encoding needed in any
position of a URI. `#` truncates at the fragment, `%` opens an invalid
percent-escape, `?` starts the query string, `:` splits userinfo — over 16
characters, drawing at least one was the likely outcome rather than the edge
case, and the failure was not always clean.

**Valkey is narrower than the other three, on purpose.** The ElastiCache AUTH
token is governed by an *allowlist* (`! & # $ ^ < > -`) rather than a blocklist,
and `-` is its only member that is also RFC 3986 unreserved — so `_`, `.` and
`~` would be rejected by the API. Details in
[`_modules/valkey-elasticache/README.md`](../../_modules/valkey-elasticache/README.md).

Entropy went up, not down: 32 characters over 66 symbols is ~193 bits (63
symbols and ~191 bits for Valkey), against the old ~104.

Nothing to check before the first release, and nothing to percent-encode.

> The `br-sfn` chart states the same rule in words — *"passwords must be URL-safe
> (no `@ : / ? # %`)"* — for the same reason. It was never specific to Pix.

> **One-time migration cost.** Narrowing the character sets regenerates the
> passwords, so the first `apply` after this change **rotates** every credential
> in the table above. Workloads holding the old values fail authentication until
> External Secrets resyncs and the pods restart. Roll it dev → stg → prd, in a
> window.

---

## Why these four

From the chart discovery in
`infrastructure/IAC/product-infra-dependencies.yaml`, confirmed against
`infrastructure/K8S/helm/charts/plugin-br-pix-switch/` (chart
**2.0.0-beta.1+**):

```yaml
plugin-br-pix-switch:
  postgresql: yes   # todos subcharts off por default -- producao espera RDS/DocumentDB/ElastiCache
  mongodb:    yes
  valkey:     yes
  rabbitmq:   yes
  redpanda:   no
```

All four subcharts are declared and **all four ship disabled**, with comments
that name the managed services by hand:

| Subchart | Default | The chart's own comment |
|---|---|---|
| `postgresql` (Bitnami) | `enabled: false` | *"For external Postgres set `enabled: false` and configure `DATABASE_URL` per component"* (`values.yaml:1402-1403`) |
| `valkey` (Bitnami, OCI) | `enabled: false` | *"For external Valkey/ElastiCache set `enabled: false` and configure `VALKEY_URL`"* (`values.yaml:1422-1423`) |
| `mongodb` (Bitnami) | `enabled: false` | *"For external Mongo/DocumentDB/Atlas set `enabled: false` and configure `dictHub.secrets.MONGO_URL`"* (`values.yaml:1440-1441`) |
| `rabbitmq` (groundhog2k) | `enabled: false` | *"For external RabbitMQ / AmazonMQ set `enabled: false`"* (`values.yaml:1493-1494`) |

**This chart was designed for exactly this Terraform.** There is nothing to turn
off — the defaults are already right.

**No streaming.** A grep for `STREAMING`, `KAFKA`, `REDPANDA` or `BROKER` over
the whole chart returns nothing, matching the discovery YAML.

### Which component uses what

Ten components, and the datastores are far from evenly spread:

| Component | Postgres | Mongo | Valkey | RabbitMQ |
|---|:--:|:--:|:--:|:--:|
| `spi` (SPI/api) | ✔ | | ✔ | |
| `spiSystemplane` | ✔ | | | |
| `dictHub` (DICT hub) | ✔ | ✔ | ✔ | |
| `dictHubVsync` (worker) | ✔ | | ✔ | ✔ |
| `dictProxy` | | | | |
| `dictSystemplane` | ✔ | | | |
| `cobHub` | ✔ | | | |
| `cobProxy` | | | | |
| `cobSystemplane` | ✔ | | | |
| `adapterBtgMock` (dev only) | | | | |

`adapterBtgMock` is `enabled: false` in production; everything else defaults on.

**Mongo and RabbitMQ each serve one component.** If `dictHub` or `dictHubVsync`
is disabled in a deployment, that datastore is not needed at all — worth checking
before paying for it, especially DocumentDB, whose floor is `db.t3.medium`.

---

## The chart provisions its own databases and users

Two bootstrap Jobs, both **off by default**, both using the ADMIN credentials
these roots create:

### `global.externalPostgresDefinitions` → `templates/bootstrap-postgres.yaml`

One Job per database — `pix-spi`, `pix-dict`, `pix-cob` (`values.yaml:68-71`).
Each connects as the admin user to the hardcoded `postgres` maintenance database
and, idempotently:

- `CREATE ROLE "pixswitch" LOGIN PASSWORD …` if `pg_roles` has no such row,
- `CREATE DATABASE "pix-spi" OWNER "pixswitch"` if `pg_database` has none,
- grants on the database, the `public` schema, its tables and sequences, plus
  matching `ALTER DEFAULT PRIVILEGES`.

**So `database_name` on the postgres root is not one of the three.** It is the
instance's initial database (`pixswitch`) and nothing in the release reads it.

**And `username` stays `postgres`** — the ADMIN account the Job authenticates
with, which is what `postgresAdminLogin.username` defaults to (`values.yaml:79`).
The **application** role (`pixswitch`) is created by the Job from a password the
operator supplies, and it is that password — not the one behind `secret_name` —
that goes into the DSNs.

> The chart says it plainly: *"Never put real admin passwords in values.yaml"*
> (`values.yaml:61`). Use `postgresAdminLogin.useExistingSecret.name` and point it
> at a Secret populated from `secret_name`.

### `global.externalMongoDefinitions` → `templates/bootstrap-mongodb.yaml`

Creates the `pixswitch` user with `readWrite` on `pix-dict` (and on `pix-cob`, a
forward-compat slot nothing reads today), authenticating as the root user with
`--authenticationDatabase admin`.

> **The root username is a real trap.** The chart defaults
> `mongoAdminLogin.username` to **`root`** (`values.yaml:109`); the DocumentDB
> master username defaults to **`docdbadmin`**. They must match or the Job cannot
> authenticate. The documentdb root emits the Terraform value for that exact key
> so they cannot drift.

---

## Deploy order

```
1. examples/aws/bootstrap                    (state bucket + lock table, per env)
2. examples/aws/infra-base/vpc               -> lerian-{env}-vpc
3. examples/aws/infra-base/eks               -> lerian-{env}-eks
4. examples/aws/products/shared-resources/*  -> shared-{env}-*  (OPTIONAL, only for mode = "shared")
5. products/plugin-br-pix-switch/{postgres,documentdb,valkey,rabbitmq}   <- in any order, in parallel
6. helm upgrade --install plugin-br-pix-switch ...
   with global.externalPostgresDefinitions.enabled = true and
        global.externalMongoDefinitions.enabled    = true on the first release,
   so the chart creates the three databases, the roles and the Mongo user
```

Step 2 is the one hard prerequisite in `dedicated` mode: every root looks the VPC
up by `tag:Name`.

**Step 3 is not.** Each root resolves the EKS node security group with
`data "aws_security_groups"` — the plural data source, which returns an empty
list instead of failing. `check "eks_node_security_group_resolved"` warns until
the cluster exists; until then ingress comes from the `Type=private` subnet
CIDRs.

**Step 4 only matters to a root running `mode = "shared"`.**

The four roots in step 5 have **no dependency on each other**. Separate state
files, separate locks, separate blast radius — run them in parallel.

---

## Dedicated or shared

Every root takes `mode`:

| `mode` | What the stack does | Resources created |
|---|---|---|
| `dedicated` (default) | Creates the datastore under the plugin-br-pix-switch name, with its own security group and secret. | All of them |
| `shared` | Creates nothing. Resolves the datastore owned by the matching `products/shared-resources/<service>` root **by name**, plus its secret from Secrets Manager. | None |

```
dedicated   plugin-br-pix-switch-dev-postgres    plugin-br-pix-switch-dev-postgres/password
shared      shared-dev-postgres                  shared-dev-postgres/password
```

| Module | Data source | Name resolved |
|---|---|---|
| `postgres-rds` | `aws_db_instance` | `shared-{env}-postgres` |
| `mongodb-documentdb` | `aws_rds_cluster` | `shared-{env}-docdb` |
| `valkey-elasticache` | `aws_elasticache_replication_group` | `shared-{env}-valkey` |
| `rabbitmq-amazonmq` | `aws_mq_broker` | `shared-{env}-rabbitmq-single` \| `-cluster` |

DocumentDB reads through `aws_rds_cluster` because the AWS provider ships no
`data "aws_docdb_cluster"` at all.

**RabbitMQ is the one that needs help.** `data "aws_mq_broker"` matches the name
exactly, the provider has no list/filter data source for MQ, and the broker name
carries a `-single` / `-cluster` topology suffix — so it has to be **declared**,
through `shared_broker_name`. The default derives
`shared-{env}-rabbitmq-single`, matching the shared tier's dev shape; stg and prd
run `CLUSTER_MULTI_AZ`, so a shared consumer there sets
`shared_broker_name = "shared-{env}-rabbitmq-cluster"`. The secret and the
security group never carry the suffix.

> **A shared datastore does not remove the bootstrap step.** The chart's Jobs
> still have to create `pix-spi` / `pix-dict` / `pix-cob` and the `pixswitch`
> role — on a shared instance, alongside every other product's databases. Check
> for name collisions before pointing this product at the shared tier: the three
> database names carry no product prefix.

---

## Running a stack

```bash
cd examples/aws/products/plugin-br-pix-switch/postgres

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/plugin-br-pix-switch/postgres/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

`../../../` is **three** levels up and lands on `examples/aws`, where both
`backend/` and `_modules/` live. Verified with `terraform init`.

| Stack | State key |
|---|---|
| postgres | `aws/products/plugin-br-pix-switch/postgres/terraform.tfstate` |
| documentdb | `aws/products/plugin-br-pix-switch/documentdb/terraform.tfstate` |
| valkey | `aws/products/plugin-br-pix-switch/valkey/terraform.tfstate` |
| rabbitmq | `aws/products/plugin-br-pix-switch/rabbitmq/terraform.tfstate` |

`*.tfvars` is gitignored; `*.tfvars-example` is not.

---

## What gets created

With `mode = "dedicated"` and `environment = "dev"`:

| Stack | AWS resource | Secrets Manager |
|---|---|---|
| postgres | `plugin-br-pix-switch-dev-postgres` (RDS) | `plugin-br-pix-switch-dev-postgres/password` |
| documentdb | `plugin-br-pix-switch-dev-docdb` (DocumentDB) | `plugin-br-pix-switch-dev-docdb/password` |
| valkey | `plugin-br-pix-switch-dev-valkey` (ElastiCache) | `plugin-br-pix-switch-dev-valkey/auth-token` |
| rabbitmq | `plugin-br-pix-switch-dev-rabbitmq-single` (AmazonMQ) | `plugin-br-pix-switch-dev-rabbitmq/password` |

The AWS suffix is `docdb` and the chart says `MONGO`. Intentional — `docdb` is
the service, `mongodb` is what the application speaks.

> The product name is the longest in the fleet, and the derived names are
> correspondingly long. The tightest limit any of them meets is the ElastiCache
> replication group id (40 characters); `plugin-br-pix-switch-prd-valkey` is 31.

---

## Per-datastore notes

Full detail is in each root's README; the headline for each:

### postgres

DSNs, not host/port. Three databases created by the chart's bootstrap Job.
Master user is the **admin** account, application role is a separate credential.
See [`postgres/README.md`](postgres/README.md).

### documentdb — read this one

**The chart's own `MONGO_URL` example is wrong for DocumentDB.**
`values-template.yaml:87` shows
`mongodb://user:<password>@mongo-host:27017/?authSource=admin`, which is missing
**`retryWrites=false`**.

DocumentDB does not implement retryable writes and every modern driver enables
them by default. Without that parameter the connection succeeds and **every write
fails** — which reads like an application bug rather than a connection-string
bug. The `mongo_url_template` output emits it; so does the `mongo_parameters`
output, published separately so it cannot be dropped while assembling the URL by
hand.

`documentdb_tls` stays `"disabled"`, and here there are **two** blockers rather
than one: the chart has no CA-bundle key at all (its whole Mongo surface is the
one URL secret), and its bootstrap Job runs `mongosh` with no `--tls` flag. See
[`documentdb/README.md`](documentdb/README.md).

### valkey

`helm_values` is empty; `valkey_url_template` carries the shape into **three**
components. `redis://` (not `valkey://`) is correct — Valkey speaks the Redis
wire protocol. `rediss://` appears only when `transit_encryption_mode` is
`"required"`, which stays `"preferred"` in every environment. See
[`valkey/README.md`](valkey/README.md).

### rabbitmq

`helm_values` is empty; `rabbitmq_uri_template` carries the shape. **This is the
best-aligned pairing in the product**: the chart already specifies `amqps` on
5671 (which is all AmazonMQ serves) and disabled its embedded broker specifically
because a self-signed certificate is rejected by lib-commons — exactly the
problem a managed broker with a publicly-trusted certificate removes. See
[`rabbitmq/README.md`](rabbitmq/README.md).

---

## Secrets

No stack outputs a password. Each one outputs `secret_name` and `secret_arn`; the
value is read from Secrets Manager by External Secrets Operator and then
**composed into a URL** — which is why the URL-safety section above matters.

| Stack | Secret (dedicated) | Whose password |
|---|---|---|
| postgres | `plugin-br-pix-switch-{env}-postgres/password` | the **admin** account |
| documentdb | `plugin-br-pix-switch-{env}-docdb/password` | the **root** account |
| valkey | `plugin-br-pix-switch-{env}-valkey/auth-token` | the AUTH token (unenforced) |
| rabbitmq | `plugin-br-pix-switch-{env}-rabbitmq/password` | the broker admin |

**The application credentials are different.** `pixswitch` (Postgres role and
Mongo user) is created by the chart's bootstrap Jobs from a password the operator
supplies to `pixswitchCredentials`, and it is that password that belongs in the
DSNs — not the admin one.

---

## Dev cost

Approximate `us-east-1` on-demand, `mode = "dedicated"`, minimum sizing:

| Stack | Sizing | ~USD/month |
|---|---|---|
| postgres | `db.t4g.micro`, 20 GB | 15 |
| valkey | `cache.t4g.micro`, 1 node | 12 |
| rabbitmq | `mq.m7g.medium`, SINGLE_INSTANCE | 100 |
| documentdb | `db.t3.medium`, 1 instance | 60 |
| **total** | | **~187** |

*Estimates. Price them against your own AWS Pricing Calculator.*

Two of those have no cheap corner:

- **RabbitMQ.** AmazonMQ offers the RabbitMQ engine only the `mq.m5.*` and
  `mq.m7g.*` families; `mq.m7g.medium` is the smallest at ~USD 100/month. The
  burstable `mq.t3.micro` is **ActiveMQ-only** and AmazonMQ refuses it for
  RabbitMQ in every deployment mode — the module validates the family at plan
  time. Dev's only lever is `SINGLE_INSTANCE`.
- **DocumentDB.** `db.t3.medium` is the smallest class the service offers; the
  RDS micro/small range does not exist for it, and the module rejects those
  values with a plan-time precondition.

Both serve **one component each** (`dictHubVsync` and `dictHub`). If those
components are disabled in a deployment, skip the datastore entirely — that is
USD 160/month of the total. Otherwise `mode = "shared"` is the lever.

---

## Sizing traps

Caught at **plan** time unless noted:

- **`engine_version` on PostgreSQL stays MAJOR-only (`"16"`).** AWS retired 16.3
  and every apply that pinned it started failing with
  `Cannot find version 16.3 for postgres`. Caught only at apply, in a real
  account.
- **Performance Insights on `db.t4g.micro`.** Not offered on t2/t3/t4g micro and
  small.
- **`mq.t3.*` on the RabbitMQ engine.** ActiveMQ-only; the smallest RabbitMQ
  broker is `mq.m7g.medium`.
- **DocumentDB below `db.t3.medium`.** The micro/small range does not exist for
  the service.
