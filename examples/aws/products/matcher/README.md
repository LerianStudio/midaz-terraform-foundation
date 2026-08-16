# products/matcher

AWS datastores for the **Matcher** product: reconciliation of the Midaz ledger
against banks, PSPs and ERPs.

Three independent root stacks, one per datastore:

```
examples/aws/products/matcher/
├── postgres/     -> _modules/postgres-rds         matcher-{env}-postgres
├── valkey/       -> _modules/valkey-elasticache   matcher-{env}-valkey
└── rabbitmq/     -> _modules/rabbitmq-amazonmq    matcher-{env}-rabbitmq
```

Everything structural — the `lerian-{env}-vpc` / `lerian-{env}-eks` derivations,
the `shared-{env}-*` resolution of the shared tier, the ingress model, the
`check` block, the provider and backend blocks — is identical to
[`products/midaz`](../midaz/README.md) and is not re-explained here.

---

## ⚠ Inferred composition — the chart is NOT in this repository

**Read this before using anything in this directory.**

`infrastructure/K8S/helm/charts/matcher/` contains exactly one thing:

```
matcher/
└── charts/
    ├── postgresql-16.3.5.tgz
    ├── valkey-2.4.7.tgz
    └── rabbitmq-2.1.11.tgz
```

No `Chart.yaml`. No `values.yaml`. No `values-template.yaml`. No `templates/`.
No `Chart.lock`. No `README.md`. Only the vendored dependency tarballs a
`helm dependency update` left behind, from a chart whose own source lives
somewhere else.

### What that does and does not let us conclude

| Conclusion | Confidence | Why |
|---|---|---|
| The chart declares `postgresql`, `valkey` and `rabbitmq` dependencies | **high** | those three tarballs are there, and at exactly the versions the other Lerian charts pin (16.3.5 / 2.4.7 / 2.1.11) |
| The chart declares **no** MongoDB dependency | **high** | no `mongodb-*.tgz` was vendored, while three sibling charts do vendor one |
| The chart declares **no** Kafka/RedPanda dependency | **high** | same reasoning |
| All three datastores are **required at runtime** | **low** | see below |
| The env var names the application reads | **none** | nothing about the application is recoverable from a dependency tarball |

The third row is the trap. **`plugin-br-bank-transfer` vendors the identical
`rabbitmq-2.1.11.tgz` and ships that subchart `enabled: false`, with the
application's own `RABBITMQ_ENABLED` defaulting to `"false"` on top.** A vendored
tarball proves a dependency is *declared*, not that it is *used*. At roughly USD
100/month for the smallest AmazonMQ RabbitMQ broker, that distinction is the most
expensive open question in this directory.

> **CONFIRMAR com o time Matcher:**
> 1. Is the broker actually used at runtime, or is it a declared-but-disabled
>    dependency? If disabled, `rabbitmq/` should not be applied at all.
> 2. What are the application's env var names for each datastore?
> 3. Does the application have a PostgreSQL read path (a read replica is off even
>    in prd here, for that reason)?
> 4. Does it need a bucket, and does the embedded MCP server have infrastructure
>    of its own? Neither is inferable from the tarballs.

### Every `helm_values` here is empty, on purpose

Each root exports `helm_values = {}` with a comment block explaining why. The
resource names, endpoints, ports and secret paths are all real and verifiable —
they come from AWS. The env var names are not, and this repository has been
bitten three times by assuming one chart's names apply to another:

- **midaz** removed `REDIS_PORT` in chart 3.0 and folds the port into
  `REDIS_HOST`; **notifications** keeps them split;
  **plugin-br-pix-indirect-btg** does *both*, depending on the component.
- `RABBITMQ_PORT_HOST` is the **AMQP** port in the midaz chart and the
  **management** port in the notifications chart. Same two names, swapped
  meanings.
- The PostgreSQL host key is `POSTGRES_HOST` in two charts, `DB_HOST` in a third
  and `DB_ONBOARDING_HOST` / `DB_TRANSACTION_HOST` in a fourth.

An invented map would look authoritative and break in production. An empty one is
honest and costs a five-minute conversation.

Wire the release from the individual outputs in the meantime:

```bash
cd examples/aws/products/matcher/postgres
terraform output endpoint database_name username port secret_name
```

### `database_name` and `username` are infrastructure choices

With no chart to read, there is no application default to follow. So:

- `database_name = "matcher"` — an initial database has to be called something,
  and naming it after the product claims nothing about the application's
  configuration. It is published as the `database_name` output; point the release
  at that value rather than assuming it.
- `username = "postgres"` — deliberately the generic RDS default rather than
  something product-shaped. An application-looking username would be a guess
  dressed up as a contract.

Reconcile both with the chart when the chart exists.

### When the chart lands

1. Read its `values.yaml` and its ConfigMap templates — **not** another
   product's.
2. Fill in `helm_values` in each root with the names that are actually there.
3. Delete the "Helm handoff — DELIBERATELY EMPTY" block from each `outputs.tf`
   and this section from this README.
4. Re-check the composition: if the chart turns out to need S3 or MSK, add
   `matcher/s3/` or `matcher/msk/` following the shape of the roots here.

---

## Deploy order

```
1. examples/aws/bootstrap                (state bucket + lock table, per env)
2. examples/aws/infra-base/vpc           -> lerian-{env}-vpc
3. examples/aws/infra-base/eks           -> lerian-{env}-eks
4. examples/aws/products/shared-resources/*  (OPTIONAL, only for mode = "shared")
5. products/matcher/{postgres,valkey}    <- in parallel
   ...and rabbitmq/ ONLY after confirming the broker is really used
6. helm upgrade --install matcher ...    (wiring the values by hand, for now)
```

Step 2 is the one hard prerequisite. Step 3 is not: the EKS node security group
is resolved with the plural `data "aws_security_groups"`, which returns an empty
list instead of failing, so these stacks apply before the cluster exists and pick
the security group up on the next apply.

State keys:

| Stack | State key |
|---|---|
| postgres | `aws/products/matcher/postgres/terraform.tfstate` |
| valkey | `aws/products/matcher/valkey/terraform.tfstate` |
| rabbitmq | `aws/products/matcher/rabbitmq/terraform.tfstate` |

```bash
cd examples/aws/products/matcher/postgres

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/matcher/postgres/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

---

## Dedicated or shared

Every root takes `mode`, exactly as in `products/midaz`:

| `mode` | What the stack does | Resources created |
|---|---|---|
| `dedicated` (default) | Creates the datastore under the matcher name, with its own security group and secret | all of them |
| `shared` | Creates nothing. Resolves the datastore owned by the matching `products/shared-resources/<service>` root by name | none |

For the RabbitMQ root, `shared` mode needs `shared_broker_name` in stg and prd:
the shared tier runs `CLUSTER_MULTI_AZ` there and the derived default assumes
`-single`. Getting it wrong fails the plan naming the broker it searched for.

---

## What gets created

With `mode = "dedicated"` and `environment = "dev"`:

| Stack | AWS resource | Secrets Manager |
|---|---|---|
| postgres | `matcher-dev-postgres` (RDS) | `matcher-dev-postgres/password` |
| valkey | `matcher-dev-valkey` (ElastiCache) | `matcher-dev-valkey/auth-token` |
| rabbitmq | `matcher-dev-rabbitmq-single` (AmazonMQ) | `matcher-dev-rabbitmq/password` |

---

## Dev cost

Approximate `us-east-1` on-demand, `mode = "dedicated"`, minimum sizing:

| Stack | Sizing | ~USD/month |
|---|---|---|
| postgres | `db.t4g.micro`, 20 GB | 15 |
| valkey | `cache.t4g.micro`, 1 node | 12 |
| **subtotal (confirmed-ish)** | | **~27** |
| rabbitmq (**unconfirmed**) | `mq.m7g.medium`, SINGLE_INSTANCE | 100 |
| **total if the broker is real** | | **~127** |

*Estimates. Price them against your own AWS Pricing Calculator before committing
to a size.*

The broker is roughly four times the other two datastores combined and its
necessity is the least certain thing in this directory. There is no cheaper
AmazonMQ option: only the `mq.m5.*` and `mq.m7g.*` families are accepted for the
RabbitMQ engine, and the burstable `mq.t3.micro` (~USD 20/month) is
**ActiveMQ-only**. Confirm before applying, or start with `mode = "shared"`.
