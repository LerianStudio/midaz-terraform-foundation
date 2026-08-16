# products/br-sisbajud

AWS datastores for **br-sisbajud** — the Lerian SISBAJUD plugin: judicial asset
blocking and unblocking integrated with BACEN SISBAJUD.

Three independent root stacks, one per datastore:

```
examples/aws/products/br-sisbajud/
├── postgres/   -> _modules/postgres-rds       br-sisbajud-{env}-postgres
├── valkey/     -> _modules/valkey-elasticache br-sisbajud-{env}-valkey
└── msk/        -> _modules/streaming-msk      br-sisbajud-{env}-msk
```

Everything structural — the `lerian-{env}-vpc` / `lerian-{env}-eks` derivations,
the `shared-{env}-*` resolution of the shared tier, the ingress model, the
`check` blocks, the provider and backend blocks — is identical to
[`products/midaz`](../midaz/README.md), which is the template. **The chart
mapping is not.** Read the Helm section below before copying anything from
there.

---

## Why these three

From the chart discovery in
`infrastructure/IAC/product-infra-dependencies.yaml`, confirmed against
`infrastructure/K8S/helm/charts/br-sisbajud/` (chart **1.1.0**, appVersion
`1.0.0-beta.109`):

```yaml
br-sisbajud:
  postgresql: yes
  mongodb:    no
  valkey:     yes
  rabbitmq:   no
  redpanda:   yes   # STREAMING_BROKERS required; rpk job creates 6 topics
```

The chart declares exactly two subcharts, both **condition-gated and both
default OFF**, because the target environments run managed services:

| Chart dependency | Version | Repository | Turn off with |
|---|---|---|---|
| `postgresql` | 16.3.5 | charts.bitnami.com/bitnami | `postgresql.enabled: false` + `postgresql.external: true` |
| `valkey` | 2.4.7 | oci://registry-1.docker.io/bitnamicharts | `valkey.enabled: false` + `valkey.external: true` |

Kafka is never a subchart. It is reached through the `STREAMING_*` contract and
is always an external broker — on AWS, MSK.

**No DocumentDB and no RabbitMQ.** There is no `mongodb` dependency and no AMQP
variable anywhere in the chart; a grep for `RABBITMQ`, `AMQP` or `MONGO` returns
nothing. That matches the discovery YAML exactly.

### Streaming is not optional here

This is the sharpest difference from midaz. In the midaz chart streaming is
**off** by default and there is no `msk/` directory at all. In br-sisbajud:

- `STREAMING_ENABLED` defaults to **`"true"`** (`values-template.yaml:23`)
- `STREAMING_BROKERS` is marked **REQUIRED** (`values-template.yaml:24`)
- the README states *"a producer with `STREAMING_ENABLED=true` and empty
  `STREAMING_BROKERS` fails closed at boot by design"*

So a broker is **mandatory**. See [`msk/README.md`](msk/README.md) for the part
that follows from that and the part that does not: a dedicated cluster is
**~USD 105/month minimum** and nothing in the chart asks for one.

---

## Topics are created by the chart, not by Terraform

The chart ships an **ArgoCD PreSync Job** (`templates/topics/job.yaml`) running
`rpk topic create` — list-then-create, idempotent — for six topics declared in
`values.yaml:178-184`:

```
br-sisbajud.ledger.balance.changed        + .dlq
br-sisbajud.block_account.created         + .dlq
br-sisbajud.kek.rotated                   + .dlq
```

`midaz.balance.changed` is deliberately absent: Midaz owns and creates it,
br-sisbajud only consumes it.

Terraform provisions the cluster, the SASL/SCRAM credentials and the ingress, and
stops there. `auto_create_topics_enable` stays **false** so a topic-name typo
fails loudly instead of creating a live topic with broker defaults.

> **Raise `topics.replicationFactor` to 3 in the release values.** It defaults to
> `1` (`values.yaml:176`, commented *"per-env; 3 on multi-broker prod"*), and
> every cluster the `msk/` root creates has at least three brokers. At 1, every
> SISBAJUD topic lives on a single broker and a routine broker replacement loses
> partitions. Terraform's `default_replication_factor` does **not** cover this —
> it is the broker default for topics created *without* an explicit factor, and
> `rpk topic create` passes one.

---

## Dedicated or shared

Every root takes `mode`:

| `mode` | What the stack does | Resources created |
|---|---|---|
| `dedicated` (default) | Creates the datastore under the br-sisbajud name, with its own security group and secret. | All of them |
| `shared` | Creates nothing. Resolves the datastore owned by the matching `products/shared-resources/<service>` root **by name**, through a data source, plus its secret from Secrets Manager. | None |

```
dedicated   br-sisbajud-dev-postgres    br-sisbajud-dev-postgres/password
shared      shared-dev-postgres         shared-dev-postgres/password
```

| Module | Data source | Name resolved | Secret resolved |
|---|---|---|---|
| `postgres-rds` | `aws_db_instance` | `shared-{env}-postgres` | `shared-{env}-postgres/password` |
| `valkey-elasticache` | `aws_elasticache_replication_group` | `shared-{env}-valkey` | `shared-{env}-valkey/auth-token` |
| `streaming-msk` | `aws_msk_cluster` | `shared-{env}-msk` | `AmazonMSK_shared-{env}-msk` |

**The MSK secret name is the odd one out on purpose.** AWS rejects any secret
associated with an MSK cluster whose name does not start with `AmazonMSK_`, and
additionally requires it to be encrypted with a customer managed CMK. So there is
no `{name}/password` path here; the module validates the prefix at plan time.

### `mode = "shared"` on MSK is the normal choice

Repeated here because it is the one cost decision in this product that is an
order of magnitude larger than the others:

| Stack | dev sizing | ~USD/month |
|---|---|---|
| postgres | `db.t4g.micro`, 20 GB | 15 |
| valkey | `cache.t4g.micro`, 1 node | 12 |
| **msk** | **`kafka.t3.small` x 3** | **105** |
| **total dedicated** | | **~132** |
| total with `msk` shared | | **~27** |

*Estimates. Price them against your own AWS Pricing Calculator.*

MSK has no cheap corner because of the broker **count**, not the broker size:
`kafka.t3.small` is the smallest AWS offers, the minimum is two brokers, and the
count must be a **multiple of the number of client subnets** — `infra-base/vpc`
tags three subnets `Type=database`, so the valid values are 3, 6, 9.

`dedicated` needs an argument, and the honest one is **regulatory isolation, not
performance**: a shared Kafka cluster is one topic namespace, one set of ACLs and
one retention budget for every product on it. If the deployment has to be able to
state that no other workload can read or replay judicial blocking events, that is
the argument. It is a decision to record, not one the chart already made for you.

---

## Deploy order

```
1. examples/aws/bootstrap                    (state bucket + lock table, per env)
2. examples/aws/infra-base/vpc               -> lerian-{env}-vpc
3. examples/aws/infra-base/eks               -> lerian-{env}-eks
4. examples/aws/products/shared-resources/*  -> shared-{env}-*  (OPTIONAL, only for mode = "shared")
5. products/br-sisbajud/{postgres,valkey,msk}   <- in any order, in parallel
6. helm upgrade --install br-sisbajud ...
```

Step 2 is the one hard prerequisite in `dedicated` mode: every root looks the VPC
up by `tag:Name`.

**Step 3 is not.** Each root resolves the EKS node security group with
`data "aws_security_groups"` — the plural data source, which returns an empty
list instead of failing. `check "eks_node_security_group_resolved"` warns until
the cluster exists; until then ingress comes from the `Type=private` subnet
CIDRs.

**Step 4 only matters to a root running `mode = "shared"`.**

The three roots in step 5 have **no dependency on each other**. Separate state
files, separate locks, separate blast radius — run them in parallel.

Step 6 has one ordering constraint of its own that lives inside the chart: the
PreSync topics Job and the PreSync migration Job both run at `hook-weight: -1`,
before the Deployment, so the app never boots against an unmigrated database or a
broker with no topics.

---

## `module.network` — the shared lookup

The two derived cross-stack names (`lerian-{env}-vpc`, `lerian-{env}-eks`), the
`Type=private` subnet CIDR lookup, the plural EKS node security group lookup and
`check "eks_node_security_group_resolved"` are **not** written in these three
directories. They live in
[`_modules/product-network`](../../_modules/product-network), called identically
from every root with `enabled = var.mode == "dedicated"`.

The module's own `subnet_tag_type` (`"private"`) is the **ingress** subnet
filter and is left at its default. `var.subnet_tag_type` in these roots
(`"database"`) is the **placement** filter and goes to the datastore module only.
The two are not interchangeable.

---

## Running a stack

```bash
cd examples/aws/products/br-sisbajud/postgres

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/br-sisbajud/postgres/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

`../../../` is **three** levels up and lands on `examples/aws`, where both
`backend/` and `_modules/` live. Verified with `terraform init`.

| Stack | State key |
|---|---|
| postgres | `aws/products/br-sisbajud/postgres/terraform.tfstate` |
| valkey | `aws/products/br-sisbajud/valkey/terraform.tfstate` |
| msk | `aws/products/br-sisbajud/msk/terraform.tfstate` |

`*.tfvars` is gitignored; `*.tfvars-example` is not. Copy, then edit.

---

## What gets created

With `mode = "dedicated"` and `environment = "dev"`:

| Stack | AWS resource | Secrets Manager |
|---|---|---|
| postgres | `br-sisbajud-dev-postgres` (RDS) | `br-sisbajud-dev-postgres/password` |
| valkey | `br-sisbajud-dev-valkey` (ElastiCache) | `br-sisbajud-dev-valkey/auth-token` |
| msk | `br-sisbajud-dev-msk` (MSK) | `AmazonMSK_br-sisbajud-dev-msk` |

---

## Helm handoff

Every root exports a `helm_values` map holding the **exact** env var names the
br-sisbajud chart reads:

```bash
cd examples/aws/products/br-sisbajud/postgres
terraform output -json helm_values | jq
```

Verified against chart **1.1.0** (appVersion `1.0.0-beta.109`).

**Everything lands on `brSisbajud.configmap`.** This is a `single-service` chart:
one Go binary running the HTTP API and the background workers in one process.
There is no per-component split, and `brSisbajud.configmap` is emitted
**verbatim** into the ConfigMap (no allowlist), so extra keys never need a chart
change.

### postgres → `brSisbajud.configmap`

| Terraform | Chart env var |
|---|---|
| `endpoint` | `POSTGRES_HOST` |
| `port` | `POSTGRES_PORT` |
| `username` | `POSTGRES_USER` |
| `database_name` | `POSTGRES_NAME` |
| `secret_name` → External Secrets | `POSTGRES_PASSWORD` |

**There are no `DB_*` variables in this chart.** No `DB_ONBOARDING_*`, no
`DB_TRANSACTION_*`, no `REPLICA` pair. One binary, one database.

`database_name` and `username` both default to **`br_sisbajud`, with an
underscore**, and that is deliberate on both counts. The AWS resource keeps the
hyphen (`br-sisbajud-dev-postgres`), but an unquoted PostgreSQL identifier cannot
contain one and the lib-commons migrator does not quote it. And **nothing in the
chart creates an application role** — the PreSync migration Job connects as
`POSTGRES_USER` with `POSTGRES_PASSWORD` and that role has to exist already, so
the RDS master user is made the one the chart expects.

> **The 1.0.1 rename.** Chart 1.0 called these `POSTGRES_DATABASE` and
> `POSTGRES_SSL_MODE`; 1.0.1 renamed them to `POSTGRES_NAME` and
> `POSTGRES_SSLMODE` to match the lib-commons migrator
> (`docs/UPGRADE-1.0.1.md:68,81`). The old names are dead and fail silently.

`POSTGRES_SSLMODE` is **not** emitted — a client policy decision, not an
infrastructure fact. Note that lib-commons' migrator refuses non-TLS Postgres
unless `ALLOW_INSECURE_TLS` is true; `sslmode=disable` alone is not enough
(`templates/migrations/job.yaml:19-23`).

### valkey → `brSisbajud.configmap`

| Terraform | Chart env var |
|---|---|
| `"${endpoint}:${port}"` | `REDIS_HOST` |
| `secret_name` → External Secrets | `REDIS_PASSWORD` |

**That is the whole list.** The chart defines exactly two Redis variables; a grep
over the chart returns nothing else. These midaz keys **do not exist** here:
`REDIS_TLS`, `REDIS_DB`, `MULTI_TENANT_REDIS_HOST`, `MULTI_TENANT_REDIS_PORT`,
`MULTI_TENANT_REDIS_TLS`, `REDIS_USER`.

**`REDIS_HOST` carries `host:port`** — same shape as midaz, different reason.
There is no removed `REDIS_PORT` here; the variable never existed. The chart's
in-cluster fallback renders `...svc.cluster.local.:6379`
(`templates/configmap.yaml:8`) and the `wait-for-dependencies` initContainer
**splits the value on `:`** to recover the port
(`templates/deployment.yaml:66-68`), defaulting to 6379 when nothing follows.
A bare hostname does not error — it silently probes the wrong port.

Because there is no `REDIS_TLS` key, the TLS posture cannot be communicated to
the chart at all. `transit_encryption_mode` therefore stays `"preferred"` in
every environment: ElastiCache accepts TLS and plaintext alike and the client
keeps working. `"required"` would lock it out with nothing in the values to
explain why. `auth_token_enabled` stays `false` for the matching reason — sending
an AUTH token over a plaintext connection puts the credential on the wire. Both
are documented in `valkey/envs/prd.tfvars-example`, not forgotten.

### msk → `brSisbajud.configmap`

| Terraform | Chart env var |
|---|---|
| literal `"true"` | `STREAMING_ENABLED` |
| `endpoint` (bootstrap broker list) | `STREAMING_BROKERS` |
| derived | `STREAMING_TLS_ENABLED` |
| literal `"SCRAM-SHA-512"` | `STREAMING_SASL_MECHANISM` |
| `scram_username` | `STREAMING_SASL_USERNAME` |
| `secret_name` → External Secrets | `STREAMING_SASL_PASSWORD` |

**This is the one Lerian chart with a complete streaming contract**, so it is the
one place `helm_values` can wire streaming without an `extraEnvVars` workaround.
Do not reason about it from `products/shared-resources/msk`, whose header
documents the midaz gap: midaz has **no `STREAMING_BROKERS` at all**.

The authoritative list of names is `templates/topics/job.yaml:27-32`, where the
PreSync Job declares the full set it resolves from `extraEnvVars` then
`configmap`. The same keys therefore serve both the application and the topics
Job — no duplicated wiring.

**`SCRAM-SHA-512` is not a preference.** SASL/SCRAM on MSK is SCRAM-SHA-512 only.
The chart's own upgrade doc shows `SCRAM-SHA-256` as its example
(`docs/UPGRADE-1.1.md:122`), which would fail to authenticate against MSK — the
mechanism is emitted explicitly so nobody copies that example.

The `STREAMING_SASL_*` keys are **omitted, not emptied**, when
`enable_sasl_scram` is false: the topics Job renders optional keys only when they
carry a value, so an empty string would make `rpk` attempt a SASL handshake with
no mechanism.

`STREAMING_TLS_CA_CERT` is not emitted — MSK broker certificates chain to the
public Amazon trust store. `STREAMING_CLOUDEVENTS_SOURCE` is not emitted either;
it is an application identity, correctly defaulted by the chart.

### Turning the subcharts off

```yaml
postgresql:
  enabled:  false
  external: true
valkey:
  enabled:  false
  external: true
```

Both flags matter: `enabled` controls whether the subchart is deployed, `external`
controls whether the chart's own templates treat the datastore as managed. Leaving
a subchart enabled alongside its managed counterpart deploys an in-cluster
database nobody talks to and keeps password resolution pointed at the subchart's
Secret instead of the chart's own.

---

## Not provisioned here

The chart needs two more external dependencies that are **outside the scope of
this Terraform**, and neither has an AWS datastore module:

| Dependency | Chart keys | Note |
|---|---|---|
| **Vault** (envelope encryption / KMS) | `KMS_PROVIDER`, `VAULT_ADDR`, `VAULT_AUTH_METHOD`, `VAULT_TRANSIT_MOUNT_PATH`, `VAULT_APPROLE_ROLE_ID`, `VAULT_APPROLE_SECRET_ID` | `KMS_PROVIDER` defaults to `vault`; the AppRole credentials arrive through `brSisbajud.extraEnvVars`. The `br-sisbajud.kek.rotated` topic exists because of it. |
| **Midaz ledger** | `MIDAZ_BASE_URL` | marked REQUIRED; an in-cluster service URL, not infrastructure |

`SECRET_STORE_PROVIDER` (`vault` \| `aws-secrets-manager` \| `local`) is a chart
secret with no Terraform counterpart. If a deployment sets it to
`aws-secrets-manager`, the IAM policy granting the service account access to
these secrets is not created by these roots either — the roots export
`secret_arn` for exactly that purpose.

---

## Secrets

No stack outputs a password. Each one outputs `secret_name` and `secret_arn`; the
value is read from Secrets Manager by External Secrets Operator.

| Stack | Secret (dedicated) | Secret (shared) |
|---|---|---|
| postgres | `br-sisbajud-{env}-postgres/password` | `shared-{env}-postgres/password` |
| valkey | `br-sisbajud-{env}-valkey/auth-token` | `shared-{env}-valkey/auth-token` |
| msk | `AmazonMSK_br-sisbajud-{env}-msk` | `AmazonMSK_shared-{env}-msk` |

`POSTGRES_PASSWORD` is marked **required** by the chart for external Postgres and
is read twice — by the application and by the PreSync migration Job. Wire it
before the first release.

---

## Sizing traps

Inherited from the shared modules and caught at **plan** time unless noted:

- **`engine_version` on PostgreSQL stays MAJOR-only (`"16"`).** Pinning a full
  minor is a maintenance trap — AWS retired 16.3 and every apply that pinned it
  started failing with `Cannot find version 16.3 for postgres`. Caught only at
  apply, in a real account.
- **Performance Insights on `db.t4g.micro`.** AWS does not offer it on t2/t3/t4g
  micro and small, so `performance_insights_enabled` must be `false` on the dev
  sizing.
- **MSK broker count.** Must be a multiple of the number of client subnets. With
  three `Type=database` subnets the valid values are 3, 6, 9.
- **`storage_mode = "TIERED"` on `kafka.t3.*`.** Rejected by the family. Caught
  at apply.
- **SASL/SCRAM with `PLAINTEXT` in transit.** MSK serves SASL/SCRAM over TLS
  only.
