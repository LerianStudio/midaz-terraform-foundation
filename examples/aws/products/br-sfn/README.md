# products/br-sfn

AWS datastores for **br-sfn** — the Lerian Brazilian SFN rails monorepo: SPB/STR
(TED), SPI (Pix, four binaries), SILOC (card settlement), SCR (credit
information), desk, correios (BC Correio regulatory mailbox), slc-edge and the
cockpit SPA.

Four independent root stacks, one per datastore:

```
examples/aws/products/br-sfn/
├── postgres/   -> _modules/postgres-rds        br-sfn-{env}-postgres
├── valkey/     -> _modules/valkey-elasticache  br-sfn-{env}-valkey
├── rabbitmq/   -> _modules/rabbitmq-amazonmq   br-sfn-{env}-rabbitmq
└── msk/        -> _modules/streaming-msk       br-sfn-{env}-msk
```

Everything structural — the `lerian-{env}-vpc` / `lerian-{env}-eks` derivations,
the `shared-{env}-*` resolution of the shared tier, the ingress model, the
`check` blocks, the provider and backend blocks — is identical to
[`products/midaz`](../midaz/README.md), which is the template.

**The chart mapping is not, and br-sfn is the extreme case.** Read
*The chart names almost nothing* below before copying any `helm_values` shape
from midaz.

---

## The chart names almost nothing

br-sfn is a **multi-component** chart with **no fixed env allowlist**:
`<component>.configmap` and `<component>.secrets` are emitted **verbatim** into
each component's ConfigMap and Secret (`README.md:66-72`), so new env vars never
need a chart change.

The consequence for this Terraform is large. The chart only *names* the variables
its own templates read, and that is a short list:

| Datastore | Named in the chart? | Where |
|---|---|---|
| **Postgres** | **yes, and enforced** | `templates/_helpers.tpl:474-490` — the shared migration helper reads `POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_USER`, `POSTGRES_DB`, `POSTGRES_SSLMODE`, `POSTGRES_PASSWORD` and `fail`s the render when host, user or database is missing |
| **Valkey** | one key, one rail | `values-template.yaml:74` — `correios.configmap.CACHE_ADDR`, *"valkey/redis host:port"* |
| **RabbitMQ** | one key, one rail, **a secret** | `values-template.yaml:80` — `correios.secrets.RABBITMQ_URL`, a full URL with the password in it |
| **Kafka / RedPanda** | **nothing at all** | only prose: `Chart.yaml:43-45`, `README.md:40-42,78-79` |

So two of the four `helm_values` maps here are **empty on purpose**, and one has
a single key. That is not incompleteness — it is the whole surface the chart
exposes, recorded honestly. Guessing key names would be worse than emitting
none: a wrong name lands in the ConfigMap with no error and the rail silently
falls back to a compiled-in default.

Each root's `outputs.tf` header carries the specific `# CONFIRMAR no chart` note
for what it could not confirm.

---

## Why these four

From the chart discovery in
`infrastructure/IAC/product-infra-dependencies.yaml`, confirmed against
`infrastructure/K8S/helm/charts/br-sfn/` (chart **1.1.0**, appVersion
`1.0.0-beta.1`):

```yaml
br-sfn:
  postgresql: yes
  mongodb:    no
  valkey:     yes
  rabbitmq:   yes
  redpanda:   yes   # extras: IBM MQ externo (rail SPB)
```

**The chart declares no dependencies at all**, deliberately:

> *"No dependencies on purpose: Postgres, Valkey/Redis, RabbitMQ, RedPanda and
> IBM MQ are EXTERNAL, pre-provisioned services on every target environment
> (benedita tiers and BYOC alike). This chart ships application workloads only."*
> — `Chart.yaml:43-45`

That is unusually convenient: there are no subcharts to disable, no
`*.enabled: false` / `*.external: true` pairs to remember. Every datastore is
external by contract.

**No DocumentDB.** No `mongodb` dependency and no `MONGO_*` variable anywhere in
the chart, matching the discovery YAML.

---

## Not provisioned here

Two external dependencies the chart names that this repository does **not**
create, and one the discovery YAML missed.

### IBM MQ — the SPB/STR transport

`Chart.yaml:43-45` and `README.md:76` list **IBM MQ** as an external
pre-provisioned service alongside the other four. It is the messaging transport
of the SPB/STR rail (TED settlement over RSFN), and it is the reason the `spb`
image is CGO/debian-based rather than distroless — the IBM MQ client runtime
needs it (`values.yaml:63`). The SILOC rail carries the same runtime
(`values.yaml:365`).

**AWS offers no managed IBM MQ.** AmazonMQ supports ActiveMQ and RabbitMQ only,
so `products/br-sfn/rabbitmq` is *not* it and must not be mistaken for it. IBM MQ
is a deployment-level external dependency: a queue manager the client operates
(on-premises, on EC2, or as IBM MQ on Cloud), reached over the RSFN network path.
Nothing in this Terraform provisions, configures or connects to it.

The chart names no IBM MQ variable either — like Kafka, its configuration arrives
through `spb.configmap` / `spb.secrets`, passed through verbatim.

### Object storage for the correios rail

`values-template.yaml:75-76` shows two keys the discovery YAML does not account
for:

```yaml
correios:
  configmap:
    OBJECT_STORAGE_ENDPOINT: ""
    OBJECT_STORAGE_BUCKET: ""
```

The discovery YAML lists S3 for the standalone `plugin-bc-correios` chart
(*"extras: seaweedfs/S3 (bucket bc-correios-attachments)"*) but **not** for
`br-sfn`, even though br-sfn vendors that same rail as its `correios` component
(image `ghcr.io/lerianstudio/plugin-bc-correios`).

**If the `correios` rail is enabled, this product needs an S3 bucket** and there
is no `s3/` root here. `_modules/s3-bucket` exists and the naming convention is
`{product}-{env}-{name}-{account_id}`; adding `products/br-sfn/s3/` is the
follow-up. Recorded rather than silently created — it was outside the scope this
directory was generated for.

`correios.secrets.ENCRYPTION_KEY` (AES-256, 32 bytes) is an application secret
with no Terraform counterpart.

### The cockpit SPA bakes its URLs

Not infrastructure, but it surprises people: the cockpit SPA bakes `VITE_*` URLs
at **image build time** (`README.md:81-85`). No Terraform output can reach it; an
environment that needs real URLs pins an environment-specific image build.

---

## One Postgres instance, one database per rail

Each rail that owns a schema has its own database and its own PreSync migration
Job:

| Rail | Values key | Database key it reads | Migration flavour |
|---|---|---|---|
| SPB/STR | `spb` | `POSTGRES_DB` | baked (`/app/migrations`) |
| SPI/Pix ×4 | `spi` | `POSTGRES_DB` (shared) | dedicated (`br-spi-migrations`) |
| SILOC | `siloc` | `POSTGRES_DB` | dedicated (`br-siloc-migrations`) |
| SCR | `scr` | `POSTGRES_DB` | baked, table `schema_migrations_scr` |
| desk | `desk` | `POSTGRES_DB` | baked |
| correios | `correios` | **`POSTGRES_NAME`** | baked |
| slc-edge, cockpit | — | none (stateless) | none |

RDS creates **exactly one** database at provisioning time. `database_name`
(`br_sfn`) is the **bootstrap** database; the rail databases are created on the
instance afterwards, outside Terraform. That is why `helm_values` emits
`POSTGRES_HOST` / `POSTGRES_PORT` / `POSTGRES_USER` and **not** the database name.

> **`correios` reads `POSTGRES_NAME`, every other rail reads `POSTGRES_DB`.** Not
> a typo — `templates/correios/migrations-job.yaml:3` passes
> `dbCfgKey = "POSTGRES_NAME"` to the shared helper, which otherwise defaults to
> `POSTGRES_DB`. Both sides agree; do not "fix" one of them.

The four SPI components (`api`, `dict`, `brcode`, `core`) share `spi.configmap`
and `spi.secrets`, so SPI takes the map once.

---

## The generated passwords may not be URL-safe

**The one cross-cutting trap in this product. Check it before the first apply.**

The chart states the rule plainly:

> *"Postgres passwords must be URL-safe (no `@ : / ? # %`)."* — `README.md:51`

It has to, because the baked-flavour migration Jobs interpolate the password
straight into a connection URL with no escaping
(`templates/_helpers.tpl:604`), and `correios.secrets.RABBITMQ_URL` is a URL by
construction.

The shared modules generate passwords that violate it:

| Module | `override_special` | Forbidden characters it includes |
|---|---|---|
| `_modules/postgres-rds` | `!#$%^&*()-_=+[]{}<>:?` | `#` `%` `?` `:` |
| `_modules/rabbitmq-amazonmq` | `!#$%^&*()-_+{}<>?` | `#` `%` `?` |

Over 16 characters, hitting at least one is the likely outcome. The failure is
not clean: `#` truncates the URL at the fragment, `%` starts an invalid
percent-escape, `?` opens a query string, `:` breaks the userinfo split.

These roots do **not** work around it — the passwords belong to the shared
modules and every other product uses them. Do one of:

- read `secret_name`, check the value, rotate it in Secrets Manager (and on the
  instance/broker) until it is URL-safe;
- percent-encode the password on its way into the chart value; or
- for Postgres, prefer the *dedicated*-flavour migrator images (`spi`, `siloc`),
  which take the `POSTGRES_*` env contract instead of building a URL.

Narrowing `override_special` in the shared modules is the real fix. It affects
every product, so it belongs upstream, not in this directory.

---

## Dedicated or shared

Every root takes `mode`:

| `mode` | What the stack does | Resources created |
|---|---|---|
| `dedicated` (default) | Creates the datastore under the br-sfn name, with its own security group and secret. | All of them |
| `shared` | Creates nothing. Resolves the datastore owned by the matching `products/shared-resources/<service>` root **by name**, plus its secret from Secrets Manager. | None |

```
dedicated   br-sfn-dev-postgres    br-sfn-dev-postgres/password
shared      shared-dev-postgres    shared-dev-postgres/password
```

| Module | Data source | Name resolved | Secret resolved |
|---|---|---|---|
| `postgres-rds` | `aws_db_instance` | `shared-{env}-postgres` | `shared-{env}-postgres/password` |
| `valkey-elasticache` | `aws_elasticache_replication_group` | `shared-{env}-valkey` | `shared-{env}-valkey/auth-token` |
| `rabbitmq-amazonmq` | `aws_mq_broker` | `shared-{env}-rabbitmq-single` \| `-cluster` | `shared-{env}-rabbitmq/password` |
| `streaming-msk` | `aws_msk_cluster` | `shared-{env}-msk` | `AmazonMSK_shared-{env}-msk` |

**RabbitMQ is the one that needs help.** `data "aws_mq_broker"` matches the name
exactly, the provider has no list/filter data source for MQ, and the broker name
carries a `-single` / `-cluster` topology suffix — so the suffix has to be
**declared**, through `shared_broker_name`. The default derives
`shared-{env}-rabbitmq-single`, which matches the shared tier's dev shape; stg
and prd run `CLUSTER_MULTI_AZ`, so a shared consumer there sets
`shared_broker_name = "shared-{env}-rabbitmq-cluster"`. The secret and the
security group never carry the suffix.

**The MSK secret name is the other odd one.** AWS rejects any secret associated
with an MSK cluster whose name does not start with `AmazonMSK_`, and requires it
to be encrypted with a customer managed CMK — so there is no `{name}/password`
path there.

### `mode = "shared"` on MSK is the normal choice

| Stack | dev sizing | ~USD/month |
|---|---|---|
| postgres | `db.t4g.micro`, 20 GB | 15 |
| valkey | `cache.t4g.micro`, 1 node | 12 |
| rabbitmq | `mq.m7g.medium`, SINGLE_INSTANCE | 100 |
| **msk** | **`kafka.t3.small` × 3** | **105** |
| **total dedicated** | | **~232** |

*Estimates. Price them against your own AWS Pricing Calculator.*

Two of those four have no cheap corner and both surprise people:

- **RabbitMQ.** AmazonMQ offers the RabbitMQ engine only the `mq.m5.*` and
  `mq.m7g.*` families. `mq.m7g.medium` — the smallest — is ~USD 100/month. The
  burstable `mq.t3.micro` is **ActiveMQ-only** and AmazonMQ refuses it for
  RabbitMQ in every deployment mode; the module validates the family at plan
  time. Dev's only lever is `SINGLE_INSTANCE`.
- **MSK.** `kafka.t3.small` is the smallest broker AWS offers, the minimum is two
  brokers, and the count must be a **multiple of the number of client subnets** —
  `infra-base/vpc` tags three `Type=database` subnets, so valid values are 3, 6,
  9 and the floor is three brokers.

`dedicated` on MSK needs an argument, and the honest one is **regulatory
isolation, not performance**: a shared Kafka cluster is one topic namespace, one
set of ACLs and one retention budget for every product on it, and br-sfn talks
directly to BACEN and Nuclea over RSFN.

**But the chart-side evidence is thin** — unlike br-sisbajud, which marks
`STREAMING_BROKERS` REQUIRED, br-sfn names no streaming variable at all, so even
*whether a broker is needed* depends on which rails are enabled. Confirm with the
br-sfn service owners before provisioning either mode. See
[`msk/README.md`](msk/README.md).

---

## Deploy order

```
1. examples/aws/bootstrap                    (state bucket + lock table, per env)
2. examples/aws/infra-base/vpc               -> lerian-{env}-vpc
3. examples/aws/infra-base/eks               -> lerian-{env}-eks
4. examples/aws/products/shared-resources/*  -> shared-{env}-*  (OPTIONAL, only for mode = "shared")
5. products/br-sfn/{postgres,valkey,rabbitmq,msk}   <- in any order, in parallel
6. create the per-rail Postgres databases on the instance
7. create the Kafka topics (nothing else does — see msk/README.md)
8. helm upgrade --install br-sfn ...
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

**Steps 6 and 7 are not automated anywhere.** RDS creates one database and the
chart's migration Jobs assume the rail database and role already exist; the chart
creates no Kafka topics and calls it an environment concern. Both gaps are real
and both belong to the deployment, not to this Terraform.

---

## `module.network` — the shared lookup

The two derived cross-stack names (`lerian-{env}-vpc`, `lerian-{env}-eks`), the
`Type=private` subnet CIDR lookup, the plural EKS node security group lookup and
`check "eks_node_security_group_resolved"` are **not** written in these four
directories. They live in
[`_modules/product-network`](../../_modules/product-network), called identically
from every root with `enabled = var.mode == "dedicated"`.

The module's own `subnet_tag_type` (`"private"`) is the **ingress** subnet
filter and is left at its default. `var.subnet_tag_type` in these roots
(`"database"`) is the **placement** filter and goes to the datastore module only.

---

## Running a stack

```bash
cd examples/aws/products/br-sfn/postgres

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/br-sfn/postgres/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

`../../../` is **three** levels up and lands on `examples/aws`. Verified with
`terraform init`.

| Stack | State key |
|---|---|
| postgres | `aws/products/br-sfn/postgres/terraform.tfstate` |
| valkey | `aws/products/br-sfn/valkey/terraform.tfstate` |
| rabbitmq | `aws/products/br-sfn/rabbitmq/terraform.tfstate` |
| msk | `aws/products/br-sfn/msk/terraform.tfstate` |

`*.tfvars` is gitignored; `*.tfvars-example` is not.

---

## What gets created

With `mode = "dedicated"` and `environment = "dev"`:

| Stack | AWS resource | Secrets Manager |
|---|---|---|
| postgres | `br-sfn-dev-postgres` (RDS) | `br-sfn-dev-postgres/password` |
| valkey | `br-sfn-dev-valkey` (ElastiCache) | `br-sfn-dev-valkey/auth-token` |
| rabbitmq | `br-sfn-dev-rabbitmq-single` (AmazonMQ) | `br-sfn-dev-rabbitmq/password` |
| msk | `br-sfn-dev-msk` (MSK) | `AmazonMSK_br-sfn-dev-msk` |

The RabbitMQ broker name carries a `-single` / `-cluster` topology suffix; the
secret and the security group never do.

---

## Helm handoff

```bash
cd examples/aws/products/br-sfn/postgres
terraform output -json helm_values | jq
```

**The keys are per-component.** There is no chart-wide configmap — merge each map
into the `configmap:` (or `secrets:`) block of the rails that need it.

### postgres → every rail that owns a schema

| Terraform | Chart env var |
|---|---|
| `endpoint` | `POSTGRES_HOST` |
| `port` | `POSTGRES_PORT` |
| `username` | `POSTGRES_USER` |
| *(not emitted)* | `POSTGRES_DB` / `POSTGRES_NAME` — per rail, created outside Terraform |
| `secret_name` → External Secrets | `POSTGRES_PASSWORD` — **read the URL-safe warning above** |

`POSTGRES_SSLMODE` is not emitted: a client policy decision, not an
infrastructure fact. The helper defaults it to `disable`.

### valkey → `correios.configmap` only

| Terraform | Chart env var |
|---|---|
| `"${endpoint}:${port}"` | `CACHE_ADDR` |

One key, one rail. The chart README says the four SPI components ride a Redis
too, but names no SPI cache variable — see
[`valkey/README.md`](valkey/README.md) for the `# CONFIRMAR` note and use
`endpoint` / `port` directly meanwhile.

There is no TLS switch and no cache password key anywhere in the chart, which is
why `transit_encryption_mode` stays `"preferred"` and `auth_token_enabled` stays
`false` in every environment.

### rabbitmq → nothing emittable

`helm_values` is **empty**. The chart's only AMQP key is
`correios.secrets.RABBITMQ_URL`, a full URL with the password inside it, and this
repository never emits a password. Assemble it:

```yaml
correios:
  secrets:
    RABBITMQ_URL: "amqps://<admin_username>:<password>@<endpoint>:5671/"
```

`amqps` and `5671` are not choices — AmazonMQ publishes no plaintext AMQP
listener. `endpoint` is the raw broker host, mandatory because the certificate
covers `*.mq.{region}.on.aws` only. See
[`rabbitmq/README.md`](rabbitmq/README.md).

### msk → nothing the chart names

`helm_values` is **empty**. See [`msk/README.md`](msk/README.md): the chart names
no streaming variable at all, the values are available as `endpoint`, `port`,
`scram_username` and `secret_name`, and the key names have to come from the
br-sfn service owners. The SASL mechanism is `SCRAM-SHA-512` — the only one MSK
offers.

---

## Secrets

No stack outputs a password. Each one outputs `secret_name` and `secret_arn`.

| Stack | Secret (dedicated) | Secret (shared) |
|---|---|---|
| postgres | `br-sfn-{env}-postgres/password` | `shared-{env}-postgres/password` |
| valkey | `br-sfn-{env}-valkey/auth-token` | `shared-{env}-valkey/auth-token` |
| rabbitmq | `br-sfn-{env}-rabbitmq/password` | `shared-{env}-rabbitmq/password` |
| msk | `AmazonMSK_br-sfn-{env}-msk` | `AmazonMSK_shared-{env}-msk` |

The shared RabbitMQ secret carries no topology suffix, so it resolves whether the
shared broker is `-single` or `-cluster`.

---

## Sizing traps

Caught at **plan** time unless noted:

- **`engine_version` on PostgreSQL stays MAJOR-only (`"16"`).** AWS retired 16.3
  and every apply that pinned it started failing with
  `Cannot find version 16.3 for postgres`. Caught only at apply, in a real
  account.
- **Performance Insights on `db.t4g.micro`.** Not offered on t2/t3/t4g micro and
  small.
- **`mq.t3.*` on the RabbitMQ engine.** The burstable families are ActiveMQ-only;
  the smallest RabbitMQ broker is `mq.m7g.medium`.
- **MSK broker count.** Must be a multiple of the number of client subnets. With
  three `Type=database` subnets the valid values are 3, 6, 9.
- **`storage_mode = "TIERED"` on `kafka.t3.*`.** Rejected by the family. Caught
  at apply.
- **SASL/SCRAM with `PLAINTEXT` in transit on MSK.** SASL/SCRAM requires TLS.
