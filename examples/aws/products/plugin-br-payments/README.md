# products/plugin-br-payments

AWS datastores for **plugin-br-payments**, the Brazilian payments plugin.

One root stack, one datastore:

```
examples/aws/products/plugin-br-payments/
└── postgres/     -> _modules/postgres-rds     plugin-br-payments-{env}-postgres
```

---

## Why only one — and why that is a decision, not a gap

Most products in this repository get three or four directories. This one gets a
single `postgres/`, and the reason is written down in the service's own
architecture record rather than inferred from an empty `values.yaml`.

`Chart.yaml:38-40` of `plugin-br-payments-helm` 1.1.0 states it directly:

```
# Dependencies — plugin-br-payments only requires PostgreSQL.
# Idempotency uses PostgreSQL (ADR-003, no Redis), and async event publishing
# uses the outbox pattern with PostgreSQL (ADR-002, no message broker).
```

The ADRs themselves live in the plugin repository, in
`applications/plugins/plugin-br-payments/docs/PROJECT_RULES.md:83-89`:

| ADR | Decision | Impact |
|-----|----------|--------|
| ADR-002 | Midaz operations via outbox pattern (never direct calls from commands) | OutboxEvent inserted in same TX; dispatcher retries with backoff |
| ADR-003 | No Redis — idempotency in PostgreSQL, token cache in-process (`sync.RWMutex`) | Simplifies deployment; encryption-at-rest for credentials |

Both are enforced in code, not just documented —
`internal/bootstrap/fiber_server.go:62` and `:69` carry
`// ADR-003: Rate limiting is in-process per pod (no Redis).`

So:

- **No `valkey/`.** Idempotency keys are a PostgreSQL table with a unique
  constraint, the OAuth token cache is a `sync.RWMutex` map in the process, and
  rate limiting is Fiber's in-memory limiter per pod. Adding ElastiCache would
  provision a cache the chart has no environment variable to point at.
- **No `rabbitmq/` and no `msk/`.** Asynchronous publication to the Midaz ledger
  is a transactional outbox: the `OutboxEvent` row is inserted in the same
  transaction as the entity change, and a dispatcher drains it with backoff. That
  is the *point* of the pattern — a broker would reintroduce exactly the
  dual-write the ADR removes.
- **No `documentdb/`.** No Mongo variable exists anywhere in the chart.

Grep evidence over `plugin-br-payments-helm` 1.1.0: `redis` and `valkey` return
only the ADR comments and one copy-pasted helper docstring; `rabbitmq`, `amqp`,
`kafka`, `streaming`, `broker`, `redpanda` and `mongo` return **zero** matches
each, comments included.

> This differs from the automated discovery in
> `infrastructure/IAC/product-infra-dependencies.yaml`, which recorded
> `postgresql: yes` and everything else `no` with the note "ADR-002/003". The YAML
> was right. What it could not record is that the absence is *load-bearing*: a
> future reviewer who "notices" that a payments service has no cache and adds one
> would be undoing an architectural decision.

### Chart dependency

| Chart dependency | Version | Repository | Turn off with |
|---|---|---|---|
| `postgresql` | 16.3.5 | charts.bitnami.com/bitnami | `postgresql.enabled: false` + `postgresql.external: true` |

Default is `postgresql.enabled: true` (`values.yaml:325`). **Both keys matter**,
and here more than usual: `templates/deployment.yaml:88` prefers the *subchart's*
Secret for `POSTGRES_PASSWORD` whenever the subchart is enabled and not external.
Leaving `enabled: true` therefore does not merely deploy an unused database — it
makes the release ignore the credentials Terraform wrote.

---

## Dedicated or shared

| `mode` | What the stack does | Resources created |
|---|---|---|
| `dedicated` (default) | Creates the instance under the plugin-br-payments name, with its own security group and secret. | All of them |
| `shared` | Creates nothing. Resolves `shared-{env}-postgres` **by name** through `data "aws_db_instance"`, plus `shared-{env}-postgres/password` from Secrets Manager. | None |

```
dedicated   plugin-br-payments-dev-postgres    plugin-br-payments-dev-postgres/password
shared      shared-dev-postgres                shared-dev-postgres/password
```

`security_group_id` comes back `null` in shared mode: opening the shared instance
is `products/shared-resources/postgres`' job.

> **Think twice before `shared` in production here.** For most products a shared
> instance is shared *storage*. For this one it is also shared *hot path*: every
> inbound payment does an idempotency lookup and an outbox insert on this
> database. A noisy neighbour does not slow down a report, it slows down
> settlement.

---

## Deploy order

```
1. examples/aws/bootstrap                (state bucket + lock table, per env)
2. examples/aws/infra-base/vpc           -> lerian-{env}-vpc
3. examples/aws/infra-base/eks           -> lerian-{env}-eks
4. examples/aws/products/shared-resources/postgres   (OPTIONAL, only for mode = "shared")
5. products/plugin-br-payments/postgres
6. helm upgrade --install plugin-br-payments ...
```

Step 2 is the one hard prerequisite. **Step 3 is not**: the EKS node security
group is resolved with the *plural* `data "aws_security_groups"`, which returns
an empty list instead of failing, so the stack applies before the cluster exists
and picks the group up on the next apply. Until then ingress comes from the
`Type=private` subnet CIDRs.

```bash
cd examples/aws/products/plugin-br-payments/postgres

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/plugin-br-payments/postgres/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

`../../../` is **three** levels up and lands on `examples/aws`, where both
`backend/` and `_modules/` live. Verified with `terraform init`.

`*.tfvars` is gitignored; `*.tfvars-example` is not. Copy, then edit.

---

## What gets created

With `mode = "dedicated"` and `environment = "dev"`:

| Stack | AWS resource | Secrets Manager |
|---|---|---|
| postgres | `plugin-br-payments-dev-postgres` (RDS) | `plugin-br-payments-dev-postgres/password` |

---

## Helm handoff

```bash
cd examples/aws/products/plugin-br-payments/postgres
terraform output -json helm_values | jq
```

Verified against chart **plugin-br-payments-helm 1.1.0** (appVersion
`1.0.0-beta.9`), `values.yaml:199-208` (`app.configmap`, rendered by
`templates/configmap.yaml`) and `values.yaml:280` (`app.secrets`).

Everything below lands on **`.Values.app.configmap`**.

| Terraform | Chart env var |
|---|---|
| `endpoint` | `POSTGRES_HOST` |
| `port` | `POSTGRES_PORT` |
| `username` | `POSTGRES_USER` |
| `database_name` | `POSTGRES_DB` |
| `replica_endpoint` *(only when a replica exists)* | `POSTGRES_REPLICA_HOST` |
| `secret_name` → External Secrets | `app.secrets.POSTGRES_PASSWORD` |

### This chart uses `POSTGRES_*`, not midaz's `DB_*`

There is **no Lerian-wide PostgreSQL variable convention.** Three charts read for
this batch use three different spellings:

| Chart | Host variable |
|---|---|
| midaz | `DB_ONBOARDING_HOST` / `DB_TRANSACTION_HOST` |
| plugin-br-payments | `POSTGRES_HOST` |
| plugin-br-pix-direct-jd | `DATABASE_HOST` |

Each was read from its own `values.yaml` and templates. Do not copy one into
another.

The chart's own `DB_HOST` / `DB_PORT` exist only inside the optional bootstrap
Job (`templates/bootstrap-postgres.yaml`, gated by
`global.externalPostgresDefinitions.enabled`, default false). They are Job-local.
Do not wire them to the application.

### `POSTGRES_USER` and `POSTGRES_DB` — what Terraform owns

`POSTGRES_DB` **is** emitted. Unlike midaz, this product runs one logical
database, `database_name` defaults to exactly the chart's own
`plugin_br_payments`, and RDS creates it at provisioning time. It is a fact
Terraform owns.

`POSTGRES_USER` is emitted as the **RDS master** (`postgres`), not as the chart's
least-privilege default `plugin_br_payments`. That role is created by a DBA or by
the bootstrap Job — which itself expects `DB_USER_ADMIN = postgres`, so the two
agree. Once the least-privilege role exists, override `POSTGRES_USER` in the
release rather than changing `username` here: that variable renames the RDS
master and forces a replacement.

### `POSTGRES_SSLMODE` is deliberately not emitted

The chart ships `POSTGRES_SSLMODE: "require"` (`values.yaml:203`) and RDS
satisfies it on every instance, so there is nothing for Terraform to decide.

**Leave that chart key in place.** The binary's own compiled default is
`disable` (`internal/bootstrap/config.go:99`); the chart value is what upgrades
the connection. Deleting it because "Terraform doesn't set it" silently
downgrades every payment connection to plaintext.

This is also why `endpoint` is the **raw RDS hostname** and there is no private
CNAME anywhere in this repository: the RDS certificate covers
`*.{region}.rds.amazonaws.com`, and an alias in front of it breaks hostname
verification for exactly the `sslmode=require` client this chart configures.

### The read replica is opt-in, and the fallback is the opposite of midaz's

`create_read_replica = true` creates `plugin-br-payments-{env}-postgres-replica`
and makes `helm_values` emit `POSTGRES_REPLICA_HOST` / `_PORT` / `_USER` / `_DB`.

Those keys ship **commented out** in the chart (`values.yaml:209-214`, and
`:281` for the password), but nothing needs a template change to enable them:
`templates/configmap.yaml:10-14` is a generic `range` over `app.configmap`. The
binary reads all six (`internal/bootstrap/config.go:101-106`).

**With no replica, the keys are omitted entirely** — and that is the correct
shape, not an oversight:

- the application resolves "replica DSN *or primary*" when
  `POSTGRES_REPLICA_HOST` is empty (`config.go:406`), so nothing needs setting;
- it validates *conditionally* (`config.go:325-335`): as soon as **any**
  `POSTGRES_REPLICA_*` value is present, `POSTGRES_REPLICA_HOST` becomes
  mandatory, so a half-filled block fails startup;
- pointing the block at the primary — which is what `products/midaz/postgres`
  correctly does for its own chart — would move the read pool onto the writer for
  no benefit here.

`POSTGRES_REPLICA_PASSWORD` is not emitted: a read replica inherits the master
credentials, so External Secrets should populate it from the **same**
`secret_name`.

> Note the bundled Bitnami subchart already runs `architecture: replication` with
> `readReplicas.replicaCount: 1` (`values.yaml:336`, `:372`) — and nothing wires
> that replica's Service into `POSTGRES_REPLICA_HOST`. The in-cluster read
> replica has never been reachable. Switching to RDS with
> `create_read_replica = true` is the first time the CQRS read path actually gets
> a replica.

### Turning the subchart off

```yaml
postgresql:
  enabled:  false
  external: true
```

---

## Secrets

No stack outputs a password. `secret_name` and `secret_arn` are outputs; the
value is read from Secrets Manager by External Secrets Operator into the Secret
the chart consumes.

| Stack | Secret (dedicated) | Secret (shared) |
|---|---|---|
| postgres | `plugin-br-payments-{env}-postgres/password` | `shared-{env}-postgres/password` |

---

## Dev cost

Approximate `us-east-1` on-demand, `mode = "dedicated"`, minimum sizing:

| Stack | Sizing | ~USD/month |
|---|---|---|
| postgres | `db.t4g.micro`, 20 GB | 15 |
| **total** | | **~15** |

*These are estimates. Price them against your own AWS Pricing Calculator before
committing to a size.*

At roughly USD 15/month this is the cheapest complete product in the repository,
and ADR-002/ADR-003 are why: one datastore instead of three.

Two sizing traps the module catches at **plan** time:

- **Performance Insights on `db.t4g.micro`.** AWS does not offer it on t2/t3/t4g
  micro and small; `performance_insights_enabled` must be `false` on the dev
  sizing.
- **`monitoring_interval > 0` with `create_monitoring_role = false`** fails the
  apply on the missing IAM role. Keep them aligned.

And one that only shows up in a real account: **`engine_version` stays MAJOR-only
(`"16"`)**. AWS retired 16.3 and every apply that pinned it started failing with
`Cannot find version 16.3 for postgres`.

### Multi-AZ in production is not a luxury here

One instance carries the payment records, the idempotency table **and** the
outbox. An AZ loss without a standby does not just stop reads: the outbox
dispatcher stalls, so asynchronous ledger operations stop, and idempotency
enforcement stops — which is the guarantee that a retried payment is not a second
payment. `prd.tfvars-example` sets `multi_az = true`.
