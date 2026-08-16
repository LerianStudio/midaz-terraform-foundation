# products/midaz

AWS datastores for the **midaz** product: the double-entry ledger and its CRM.

This is the first product on the v2 structure, and it is the template the other
products follow. Four independent root stacks, one per datastore:

```
examples/aws/products/midaz/
├── postgres/     -> _modules/postgres-rds         midaz-{env}-postgres
├── documentdb/   -> _modules/mongodb-documentdb   midaz-{env}-docdb
├── valkey/       -> _modules/valkey-elasticache   midaz-{env}-valkey
└── rabbitmq/     -> _modules/rabbitmq-amazonmq    midaz-{env}-rabbitmq
```

---

## Why these four

From the chart discovery in `infrastructure/IAC/product-infra-dependencies.yaml`,
which was generated from `infrastructure/K8S/helm/charts/*/{Chart.yaml,values.yaml}`:

```yaml
midaz:
  postgresql: yes
  mongodb:    yes
  valkey:     yes
  rabbitmq:   yes
  redpanda:   yes   # optional, default off (STREAMING_ENABLED)
```

All four are hard dependencies. Each one is a `Chart.yaml` dependency of the
midaz chart with a `condition`, which means the chart ships a bundled in-cluster
copy by default and expects you to turn it off when a managed service exists:

| Chart dependency | Version | Repository | Turn off with |
|---|---|---|---|
| `postgresql` | 16.3.5 | charts.bitnami.com/bitnami | `postgresql.enabled: false` + `postgresql.external: true` |
| `mongodb` | 16.4.0 | charts.bitnami.com/bitnami | `mongodb.enabled: false` + `mongodb.external: true` |
| `valkey` | 2.4.7 | registry-1.docker.io/bitnamicharts | `valkey.enabled: false` + `valkey.external: true` |
| `rabbitmq` | 2.1.11 | groundhog2k.github.io/helm-charts | `rabbitmq.enabled: false` |

> `rabbitmq` has **no** `external` key in the chart's `values.yaml` — `enabled:
> false` is the whole switch. The other three have both, and both matter:
> `enabled` controls whether the subchart is deployed, `external` controls
> whether passwords come from the subchart's Secret or from the chart's own.

### Streaming / MSK is deliberately absent

There is no `msk/` directory here, and that is not an oversight.

`STREAMING_ENABLED` defaults to `"false"` in the midaz chart — and the key is not
even present in `values.yaml`; the `false` lives only in the templates
(`templates/ledger/configmap.yaml`, `templates/crm/configmap.yaml`). Provisioning
an MSK cluster for a feature that is off by default would be roughly USD 105/month
of idle broker.

If streaming is turned on:

1. **Preferred:** consume the shared cluster.
   `products/shared-resources/msk` owns `shared-{env}-msk` — an OPTIONAL,
   opt-in-by-directory root stack: applying that directory is what enables it,
   and there is no `msk_enabled` toggle any more. A product resolves it with
   `mode = "shared"` on `_modules/streaming-msk`, which reads the cluster by name
   with `data "aws_msk_cluster"` — the same by-name resolution the other four
   modules use.
2. **If midaz needs its own cluster:** add `products/midaz/msk/` as a fifth root
   following exactly the shape of the four below, with
   `mode = "dedicated"`.

> **Open item before either path works.** `STREAMING_BROKERS` **does not exist in
> the midaz chart**. The only streaming variables it defines are
> `STREAMING_ENABLED`, `STREAMING_SASL_PASSWORD` and `STREAMING_TLS_CA_CERT`.
> There is currently no chart variable that carries a broker address, so the
> bootstrap list has to be injected through `ledger.extraEnvVars` /
> `crm.extraEnvVars` until the chart grows one. Verified against chart 8.7.0.

---

## Dedicated or shared

Every root takes `mode`:

| `mode` | What the stack does | Resources created |
|---|---|---|
| `dedicated` (default) | Creates the datastore under the midaz name, with its own security group and secret. | All of them |
| `shared` | Creates nothing. Resolves the datastore owned by the matching `products/shared-resources/<service>` root **by name**, through a data source, plus its secret from Secrets Manager. | None |

`shared` is how a cost-sensitive dev environment avoids paying for four datastores
per product. It costs isolation: every product on the shared tier shares one
instance, and `security_group_id` comes back `null` because opening the shared
datastore is the `products/shared-resources/<service>` root's job, not the
product's.

The naming difference is the whole mechanism:

```
dedicated   midaz-dev-postgres     midaz-dev-postgres/password
shared      shared-dev-postgres    shared-dev-postgres/password
```

Each module resolves the shared tier through the data source AWS offers for it:

| Module | Data source | Name resolved |
|---|---|---|
| `postgres-rds` | `aws_db_instance` | `shared-{env}-postgres` |
| `mongodb-documentdb` | `aws_rds_cluster` | `shared-{env}-docdb` |
| `valkey-elasticache` | `aws_elasticache_replication_group` | `shared-{env}-valkey` |
| `rabbitmq-amazonmq` | `aws_mq_broker` | `shared-{env}-rabbitmq-single` \| `-cluster` |
| `streaming-msk` | `aws_msk_cluster` | `shared-{env}-msk` |

DocumentDB reads through `aws_rds_cluster` because the AWS provider ships no
`data "aws_docdb_cluster"` at all — DocumentDB clusters are first-class DB
clusters in the RDS control plane, and the data source returns `engine = "docdb"`
with the endpoints, the port and the master username. Verified against a real
account, not inferred from the schema.

RabbitMQ is the one that needs help: `data "aws_mq_broker"` matches the name
exactly, the provider has no list/filter data source for MQ, and the broker name
carries a `-single` / `-cluster` topology suffix — so that suffix has to be
declared. `products/midaz/rabbitmq` exposes `shared_broker_name` for it, default
`shared-{env}-rabbitmq-single` (the `shared-resources/rabbitmq` dev shape). stg
and prd run
`CLUSTER_MULTI_AZ`, so a shared consumer there sets
`shared_broker_name = "shared-{env}-rabbitmq-cluster"`.

### Two prefixes in `infra-base`, on purpose

`infra-base` hands out names under **two** prefixes and they are not a mistake to
be tidied up into one:

| Prefix | What it labels | Examples |
|---|---|---|
| `lerian-` | the **foundation** — always shared, no dedicated counterpart exists | `lerian-{env}-vpc`, `lerian-{env}-eks` |
| `shared-` | the **shared datastore tier** — the half of a dedicated/shared choice | `shared-{env}-postgres`, `shared-{env}-docdb`, `shared-{env}-valkey`, `shared-{env}-rabbitmq`, `shared-{env}-msk` |

The `shared` label only carries information where a dedicated alternative
exists. There is no `midaz-{env}-vpc` and never will be, so labelling the VPC
`shared` would say nothing.

Not resource names and therefore **not** renamed: the `lerian` PostgreSQL
database name, the `lerian` Kafka SCRAM username, and the
`Repository = "lerian-terraform-foundation"` tag.

### There is no private DNS layer

No stack here creates a CNAME, and there is no `{env}.lerian.internal` zone.
Every AWS datastore presents a certificate for its **own** service domain — RDS
`*.{region}.rds.amazonaws.com`, DocumentDB `*.docdb.amazonaws.com`, AmazonMQ
`*.mq.{region}.on.aws`, ElastiCache `*.{cluster}.{region}.cache.amazonaws.com` —
so a private alias in front of any of them breaks TLS hostname verification for
every client that validates it.

The "stable name" argument does not survive contact with the workflow either:
the Helm values are generated by `terraform output` on every deploy, so there is
no hardcoded host for a CNAME to protect. Every root therefore exports
`endpoint`, the raw AWS host, in both modes.

---

## Deploy order

```
1. examples/aws/bootstrap                (state bucket + lock table, per env)
2. examples/aws/infra-base/vpc           -> lerian-{env}-vpc
3. examples/aws/infra-base/eks           -> lerian-{env}-eks
4. examples/aws/products/shared-resources/*  -> shared-{env}-*   (OPTIONAL, only for mode = "shared")
5. products/midaz/{postgres,documentdb,valkey,rabbitmq}   <- in any order, in parallel
6. helm upgrade --install midaz ...
```

Step 2 is the one hard prerequisite: every root looks the VPC up by `tag:Name`,
and that lookup fails the plan when the target does not exist.

**Step 3 is not.** Each root resolves the EKS node security group with
`data "aws_security_groups"` — the **plural** data source, which returns an empty
list instead of failing when nothing matches. Applying the datastores before the
cluster exists works; the stack warns through
`check "eks_node_security_group_resolved"` and picks the security group up on the
next apply. Until then ingress comes from the `Type=private` subnet CIDRs, which
only depend on step 2.

**Step 4 only matters to a root running `mode = "shared"`** — that root resolves
the shared datastore by name and fails the plan if it is not there yet. A
`dedicated` deployment can skip it entirely. Steps 3 and 4 can also swap: nothing
in `products/shared-resources/*` requires the cluster, for the same
`check "eks_node_security_group_resolved"` reason as above.

The four roots in step 5 have **no dependency on each other**. Separate state
files, separate locks, separate blast radius — run them in parallel.

---

## `module.network` — the shared lookup

The two derived cross-stack names (`lerian-{env}-vpc` and `lerian-{env}-eks`),
the `Type=private` subnet CIDR lookup, the plural EKS node security group lookup
and
`check "eks_node_security_group_resolved"` are **not** written in these four
directories. They live in
[`_modules/product-network`](../../_modules/product-network), which every root
calls identically:

```hcl
module "network" {
  source = "../../../_modules/product-network"

  enabled     = var.mode == "dedicated"
  environment = var.environment

  vpc_name         = var.vpc_name
  eks_cluster_name = var.eks_cluster_name

  allow_private_subnet_cidr_ingress      = var.allow_private_subnet_cidr_ingress
  eks_node_security_group_lookup_enabled = var.eks_node_security_group_lookup_enabled

  allowed_security_group_ids = var.allowed_security_group_ids
  allowed_cidr_blocks        = var.allowed_cidr_blocks
}
```

It creates no AWS resource. `module.network.ingress_security_group_ids` and
`module.network.ingress_cidr_blocks` go straight to the datastore module's
`allowed_security_group_ids` / `allowed_cidr_blocks`, and
`module.network.vpc_name` to its `vpc_name`. `enabled` is what keeps
`mode = "shared"` free of lookups.

The module's own `subnet_tag_type` (`"private"`) is the **ingress** subnet
filter and is left at its default. `var.subnet_tag_type` in these roots
(`"database"`) is the **placement** filter and goes to the datastore module
only — the two are not interchangeable.

---

## Running a stack

Paths below are relative to the service directory and have been verified with
`terraform init`. From `examples/aws/products/midaz/postgres/`, `../../../` lands
on `examples/aws`, where both `backend/` and `_modules/` live — **three** levels
up, not four.

```bash
cd examples/aws/products/midaz/postgres

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/midaz/postgres/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

The other three, same shape:

```bash
cd examples/aws/products/midaz/documentdb
terraform init -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/midaz/documentdb/terraform.tfstate"

cd examples/aws/products/midaz/valkey
terraform init -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/midaz/valkey/terraform.tfstate"

cd examples/aws/products/midaz/rabbitmq
terraform init -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/midaz/rabbitmq/terraform.tfstate"
```

State keys:

| Stack | State key |
|---|---|
| postgres | `aws/products/midaz/postgres/terraform.tfstate` |
| documentdb | `aws/products/midaz/documentdb/terraform.tfstate` |
| valkey | `aws/products/midaz/valkey/terraform.tfstate` |
| rabbitmq | `aws/products/midaz/rabbitmq/terraform.tfstate` |

`*.tfvars` is gitignored; `*.tfvars-example` is not. Copy, then edit.

---

## What gets created

With `mode = "dedicated"` and `environment = "dev"`:

| Stack | AWS resource | Secrets Manager |
|---|---|---|
| postgres | `midaz-dev-postgres` (RDS) | `midaz-dev-postgres/password` |
| documentdb | `midaz-dev-docdb` (DocumentDB) | `midaz-dev-docdb/password` |
| valkey | `midaz-dev-valkey` (ElastiCache) | `midaz-dev-valkey/auth-token` |
| rabbitmq | `midaz-dev-rabbitmq-single` (AmazonMQ) | `midaz-dev-rabbitmq/password` |

The AWS suffix is `docdb` and the chart variables say `MONGO`. Intentional —
`docdb` is the service, `mongodb` is what the application speaks. Both sides of
the contract agree on it; do not "fix" one of them.

The RabbitMQ broker name carries a `-single` / `-cluster` topology suffix; the
secret and the security group never do. That is what lets a consumer resolve the
secret without knowing the topology, and what makes a
`SINGLE_INSTANCE -> CLUSTER_MULTI_AZ` migration a side-by-side procedure. The
broker lookup in shared mode is the one place the suffix has to be spelled out —
see `shared_broker_name` above.

---

## Helm handoff

Every root exports a `helm_values` map holding the **exact** env var names the
midaz chart reads, so wiring the release is a copy rather than a translation:

```bash
cd examples/aws/products/midaz/postgres
terraform output -json helm_values | jq
```

Verified against midaz chart **8.7.0** (appVersion 3.8.0),
`templates/ledger/configmap.yaml` and `templates/crm/configmap.yaml`.

Everything except the `MONGO_*` unsuffixed block lands on **`ledger.configmap`**.
There is no separate onboarding deployment and no separate transaction
deployment — the ledger container is unified and carries both variable sets.

### postgres → `ledger.configmap`

| Terraform | Chart env var |
|---|---|
| `endpoint` | `DB_ONBOARDING_HOST`, `DB_TRANSACTION_HOST` |
| `port` | `DB_ONBOARDING_PORT`, `DB_TRANSACTION_PORT` |
| `username` | `DB_ONBOARDING_USER`, `DB_TRANSACTION_USER` |
| `replica_endpoint` (or the primary when there is no replica) | `DB_ONBOARDING_REPLICA_HOST`, `DB_TRANSACTION_REPLICA_HOST` |
| `secret_name` → External Secrets | `DB_ONBOARDING_PASSWORD`, `DB_TRANSACTION_PASSWORD` |

There is **no plain `DB_HOST` / `DB_PORT`** on the application containers — those
names exist only inside the chart's bootstrap Jobs. Do not wire them.

`DB_ONBOARDING_NAME` and `DB_TRANSACTION_NAME` are **not** emitted. RDS creates a
single initial database (`database_name`, default `midaz`); the second logical
database is created by the application migration, so Terraform does not know
these values and must not guess them. The chart defaults are `onboarding` and
`transaction`.

The `REPLICA_*` variables are always emitted, pointed at the primary when no read
replica exists. The chart's own default for them is
`midaz-postgresql-replication`, a subchart service that stops existing the moment
`postgresql.enabled` is false — leaving them unset breaks the ledger's second
connection pool.

### documentdb → `ledger.configmap` (and `crm.configmap`)

| Terraform | Chart env var |
|---|---|
| `endpoint` | `MONGO_ONBOARDING_HOST`, `MONGO_TRANSACTION_HOST`, `MONGO_HOST` |
| `port` | `MONGO_ONBOARDING_PORT`, `MONGO_TRANSACTION_PORT`, `MONGO_PORT` |
| `master_username` | `MONGO_ONBOARDING_USER`, `MONGO_TRANSACTION_USER`, `MONGO_USER` |
| literal `"mongodb"` | `MONGO_ONBOARDING_URI`, `MONGO_TRANSACTION_URI`, `MONGO_URI` |
| derived from `documentdb_tls` | `MONGO_*_PARAMETERS` |
| `secret_name` → External Secrets | `MONGO_ONBOARDING_PASSWORD`, `MONGO_TRANSACTION_PASSWORD` |

`MONGO_*_URI` is **not** a connection string — the chart uses it for the scheme
alone and the application assembles the URI from the surrounding variables.
`mongodb` is the only correct value for DocumentDB: it publishes no SRV records,
so `mongodb+srv` cannot resolve.

`MONGO_*_PARAMETERS` carries `retryWrites=false`, which is mandatory —
DocumentDB does not implement retryable writes and every driver enables them by
default, so omitting it makes every write fail. `tls=true` is appended when
`documentdb_tls = "enabled"`.

**TLS caveat.** `MONGO_*_HOST` is always the raw `endpoint` — the
`*.docdb.amazonaws.com` name the cluster certificate actually covers — so
turning TLS on changes nothing about the host, only whether `tls=true` is
appended to `MONGO_*_PARAMETERS`. What still has to land first is the chart
mounting the global RDS CA bundle into `MONGO_*_TLS_CA_CERT`, which Terraform
cannot distribute. TLS is currently `"disabled"` in all three environments,
matching `products/shared-resources/documentdb` — documented as a known gap in
`documentdb/envs/prd.tfvars-example`, not an oversight.

The unsuffixed `MONGO_*` block belongs to **CRM** (`crm.enabled`, false by
default). It is emitted regardless so turning CRM on needs no second lookup.

`reader_endpoint` is published but unused — the chart has no read-only Mongo
variable today.

### valkey → `ledger.configmap`

| Terraform | Chart env var |
|---|---|
| `"${endpoint}:${port}"` | `REDIS_HOST` |
| derived from `transit_encryption_mode` | `REDIS_TLS` |
| `redis_db_index` | `REDIS_DB` |
| `endpoint` / `port`, split | `MULTI_TENANT_REDIS_HOST` / `MULTI_TENANT_REDIS_PORT` |
| `secret_name` → External Secrets | `REDIS_PASSWORD` |

**`REDIS_HOST` carries `host:port`, not a host.** The chart removed `REDIS_PORT`
in chart 3.0 and requires the port inline. Emitting a bare hostname produces a
ledger that dials port 0. The `MULTI_TENANT_*` pair is the exception and stays
split.

`REDIS_TLS` reports whether TLS is **required**, not whether it is available.
`transit_encryption_mode = "preferred"` means ElastiCache accepts TLS and
plaintext alike and the chart connects in plaintext, so `preferred` reports
`"false"`. Only `"required"` reports `"true"`.

`REDIS_USER` / `REDIS_USERNAME` do not exist in the chart, in any form.

### rabbitmq → `ledger.configmap`

| Terraform | Chart env var |
|---|---|
| `endpoint` | `RABBITMQ_HOST` |
| `port` (5671) | `RABBITMQ_PORT_HOST` |
| `console_port` (443) | `RABBITMQ_PORT_AMQP` |
| literal `"amqps"` | `RABBITMQ_URI` |
| literal `"https"` | `RABBITMQ_PROTOCOL` |
| `admin_username` | `RABBITMQ_DEFAULT_USER` |
| `secret_name` → External Secrets | `RABBITMQ_DEFAULT_PASS`, `RABBITMQ_CONSUMER_PASS` |

**The two port variables are named backwards in the chart.** Not a typo above —
`RABBITMQ_PORT_HOST` is the AMQP(S) port and `RABBITMQ_PORT_AMQP` is the
management HTTP port. The ledger's init container reads them that way.

`RABBITMQ_URI` and `RABBITMQ_PROTOCOL` are **schemes**, not URIs. `amqps` is
mandatory: AmazonMQ for RabbitMQ publishes no plaintext AMQP listener, so the
chart default `amqp` cannot connect at all.

**`RABBITMQ_HOST` is the raw broker host**, always, with no switch to flip. The
client speaks AMQPS and the broker certificate covers `*.mq.{region}.on.aws`
only, so it is the one host that works. The cost is that replacing the broker
changes `RABBITMQ_HOST` and is therefore a Helm values change — regenerated by
`terraform output`, so nothing is hardcoded, but the release has to be
re-rendered.

`RABBITMQ_DEFAULT_PASS` and `RABBITMQ_CONSUMER_PASS` are marked `required` by the
chart and fail the install when empty — wire them before the first release. The
module creates one broker user; a separate consumer user is created on the broker
itself, outside Terraform.

### Turning the subcharts off

```yaml
postgresql:
  enabled:  false
  external: true
mongodb:
  enabled:  false
  external: true
valkey:
  enabled:  false
  external: true
rabbitmq:
  enabled:  false     # no `external` key exists for this one
```

Leaving a subchart enabled alongside its managed counterpart deploys an
in-cluster database nobody talks to, and — for postgres, mongodb and valkey —
keeps password resolution pointed at the subchart's Secret instead of the chart's
own, so the credentials Terraform wrote are silently ignored.

---

## Secrets

No stack outputs a password. Each one outputs `secret_name` and `secret_arn`; the
value is read from Secrets Manager by External Secrets Operator into the Secret
the chart consumes.

| Stack | Secret (dedicated) | Secret (shared) |
|---|---|---|
| postgres | `midaz-{env}-postgres/password` | `shared-{env}-postgres/password` |
| documentdb | `midaz-{env}-docdb/password` | `shared-{env}-docdb/password` |
| valkey | `midaz-{env}-valkey/auth-token` | `shared-{env}-valkey/auth-token` |
| rabbitmq | `midaz-{env}-rabbitmq/password` | `shared-{env}-rabbitmq/password` |

The shared secret names carry no topology suffix, so the RabbitMQ one resolves
whether the shared broker is `-single` or `-cluster`.

The Valkey auth token is generated and stored whether or not ElastiCache enforces
it. `auth_token_enabled` is `false` in every environment because the midaz chart
has no Valkey AUTH client configuration yet — turning it on without that change
locks every consumer out. Documented as a known gap in
`valkey/envs/prd.tfvars-example`.

---

## Dev cost

Approximate `us-east-1` on-demand, `mode = "dedicated"`, minimum sizing:

| Stack | Sizing | ~USD/month |
|---|---|---|
| postgres | `db.t4g.micro`, 20 GB | 15 |
| valkey | `cache.t4g.micro`, 1 node | 12 |
| rabbitmq | `mq.m7g.medium`, SINGLE_INSTANCE | 100 |
| documentdb | `db.t3.medium`, 1 instance | 60 |
| **total** | | **~190** |

*These are estimates. Price them against your own AWS Pricing Calculator before
committing to a size.*

RabbitMQ is the surprise in that table. AmazonMQ offers the RabbitMQ engine only
the `mq.m5.*` and `mq.m7g.*` families, and `mq.m7g.medium` — the smallest of them
— is roughly `USD 100/month`. The burstable `mq.t3.micro` that would have cost
about `USD 20/month` is an **ActiveMQ-only** type: AmazonMQ refuses it for
RabbitMQ in every deployment mode. There is no cheap AmazonMQ broker to fall back
to, so dev's only lever is the node count (`SINGLE_INSTANCE`, one node instead of
three).

DocumentDB has no cheap corner: `db.t3.medium` is the smallest class the service
offers — the RDS micro/small range does not exist for it, and the module rejects
those values with a plan-time precondition rather than five minutes into the
apply. If a dev environment cannot carry that, set `mode = "shared"` on the
documentdb root and consume the shared cluster.

Two more sizing traps the modules catch at plan time rather than at apply time:

- **Performance Insights on `db.t4g.micro`.** AWS does not offer it on
  t2/t3/t4g micro and small. `performance_insights_enabled` must be `false` on
  the dev PostgreSQL sizing.
- **`mq.t3.*` on the RabbitMQ engine.** The burstable families are ActiveMQ-only.
  AmazonMQ rejects them for RabbitMQ in *every* deployment mode, `SINGLE_INSTANCE`
  included, so the smallest broker is `mq.m7g.medium`. The module validates the
  instance-type family at plan time.

And one that only shows up in a real account: **`engine_version` on PostgreSQL
stays MAJOR-only (`"16"`)**. Pinning a full minor is a maintenance trap — AWS
retired 16.3 and every apply that pinned it started failing with
`Cannot find version 16.3 for postgres`.

---

## Adding another product

Copy this directory to `examples/aws/products/<product>/`, then in each service
root:

1. Change the `product` variable's `default` **and its `validation`** — the
   validation pins the value on purpose, because the derived resource names and
   secret paths are the cross-stack discovery contract and a typo there produces
   resources the Helm release cannot find, with no error.
2. Drop the service directories the product does not use, per
   `product-infra-dependencies.yaml`.
3. Change the state key to `aws/products/<product>/<service>/terraform.tfstate`.
4. Update `helm_values` to that product's chart variable names. **Do not assume
   they match midaz's** — `REDIS_HOST` carrying `host:port` and the inverted
   `RABBITMQ_PORT_*` pair are midaz-chart conventions, not Lerian-wide ones.

Everything else — the `lerian-{env}-vpc` / `lerian-{env}-eks` derivations, the
`shared-{env}-*` resolution of the shared tier, the ingress model, the `check`
block, the provider and backend blocks — is product-independent and copies
verbatim.
