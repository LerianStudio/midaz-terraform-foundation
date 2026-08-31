# products/reporter

AWS datastores and object storage for the **reporter** product: the report
generation service (a manager API plus a KEDA-driven worker).

```
examples/aws/products/reporter/
├── documentdb/   -> _modules/mongodb-documentdb   reporter-{env}-docdb
├── valkey/       -> _modules/valkey-elasticache   reporter-{env}-valkey
├── rabbitmq/     -> _modules/rabbitmq-amazonmq    reporter-{env}-rabbitmq
└── s3/           -> _modules/s3-bucket            reporter-{env}-reporter-storage-{account_id}
```

Every directory is an independent root stack with its own state file, its own
lock and its own blast radius. They have no dependency on each other — run them
in parallel.

---

## Why these services

From the chart discovery in `infrastructure/IAC/product-infra-dependencies.yaml`:

```yaml
reporter:
  postgresql: no
  mongodb:    yes
  valkey:     yes
  rabbitmq:   yes
  redpanda:   no      # extras: seaweedfs/S3 (bucket reporter-storage), keda
```

Confirmed against `Chart.yaml`, which declares all of them as conditional
dependencies — the chart ships a bundled in-cluster copy of each and expects you
to turn it off when a managed service exists:

| Chart dependency | Version | Default | Turn off with |
| --- | --- | --- | --- |
| `mongodb` | 16.4.0 | **enabled** | `mongodb.enabled: false` + `mongodb.external: true` |
| `valkey` | 0.7.4 | **enabled** | `valkey.enabled: false` (no `external` key) |
| `rabbitmq` | 2.1.11 | **enabled** | `rabbitmq.enabled: false` (no `external` key) |
| `seaweedfs` | 4.0.393 | **enabled** | `seaweedfs.enabled: false` |
| `keda` | 2.17.1 | **enabled** | cluster workload — not Terraform's business |

> **reporter and fetcher are near-twins with one loud difference: reporter ships
> every subchart ENABLED and fetcher ships every subchart DISABLED.** It does not
> change the infrastructure either root creates — both are external — but it does
> change what happens if you forget: a reporter release with the defaults left
> alone deploys an in-cluster MongoDB, Valkey, RabbitMQ and SeaweedFS next to the
> managed ones.

There is no `postgres/` directory. reporter reads midaz's PostgreSQL through
`DATASOURCE_ONBOARDING_*` — a **client** configuration pointed at
`products/midaz/postgres`, not a datastore of its own.

---

## Dedicated or shared

Every datastore root takes `mode`:

| `mode` | What the stack does | Resources created |
| --- | --- | --- |
| `dedicated` (default) | Creates the datastore under the product name, with its own security group and secret. | all |
| `shared` | Creates nothing. Resolves the datastore owned by the matching `products/shared-resources/<service>` root **by name**, through a data source, plus its secret from Secrets Manager. | none |

The naming difference is the whole mechanism — `reporter-dev-valkey` versus
`shared-dev-valkey` — and in `shared` mode `security_group_id` comes back `null`,
because opening the shared datastore is the shared tier's job.

**The `s3` root has no `mode`.** Object storage is always owned by the product
that writes to it; see `s3/README.md`.

RabbitMQ is the one that needs help in shared mode: `data "aws_mq_broker"`
matches the name exactly, the provider has no list/filter data source for MQ, and
the broker name carries a `-single` / `-cluster` topology suffix. `stg` and `prd`
of the shared tier run `CLUSTER_MULTI_AZ`, so a consumer there sets
`shared_broker_name = "shared-{{env}}-rabbitmq-cluster"`.

## Two prefixes, on purpose

| Prefix | What it labels |
| --- | --- |
| `lerian-` | the **foundation** — `lerian-{{env}}-vpc`, `lerian-{{env}}-eks`. Always shared; no dedicated counterpart exists. |
| `shared-` | the **shared datastore tier** — `shared-{{env}}-postgres` and friends. The half of a dedicated/shared choice. |
| `reporter-` | this product's own datastores. |

That is why no root here calls the `naming` module: the two cross-stack names it
would derive carry the `lerian` label, not the product's.

## There is no private DNS layer

No stack creates a CNAME and there is no private zone. Every AWS datastore
presents a certificate for its **own** service domain — RDS
`*.{{region}}.rds.amazonaws.com`, DocumentDB `*.docdb.amazonaws.com`, AmazonMQ
`*.mq.{{region}}.on.aws`, ElastiCache `*.{{cluster}}.{{region}}.cache.amazonaws.com`
— so a private alias in front of any of them breaks TLS hostname verification.
Every root exports `endpoint`, the raw AWS host, in both modes.

## Cluster dependencies Terraform does not create

Two things this product needs from the cluster are **not** provisioned here, and
looking for them in these directories is a dead end:

- **KEDA.** The chart declares it as a dependency and drives worker autoscaling
  from RabbitMQ queue depth. It is a cluster workload; install it with the chart
  (`keda.enabled`) or point the chart at an operator installed separately
  (`keda.external: true`).
- **AWS IAM Roles Anywhere.** The chart carries a block for it, for clusters that
  are *not* EKS. On EKS it is unnecessary and unused — the `s3` root here issues
  an **IRSA** role instead, which is the EKS-native equivalent. Do not wire both.

---

## Deploy order

```
1. examples/aws/bootstrap                     state bucket + lock table, per env
2. examples/aws/infra-base/vpc                lerian-{env}-vpc
3. examples/aws/infra-base/eks                lerian-{env}-eks
4. examples/aws/products/shared-resources/*   shared-{env}-*   (OPTIONAL, only for mode = "shared")
5. products/reporter/*                       in any order, in parallel
6. helm upgrade --install reporter ...
```

Step 2 is a hard prerequisite for every datastore root: they look the VPC up by
`tag:Name` and the lookup fails the plan when it is missing.

**Step 3 is a hard prerequisite for `s3/` only.** The datastore roots tolerate a
missing cluster — they resolve the EKS node security group with the *plural*
`data "aws_security_groups"`, which returns an empty list instead of failing, and
warn through `check "eks_node_security_group_resolved"` until the cluster exists.
The `s3` root resolves the cluster OIDC provider with **singular** data sources
that fail the plan, because an IRSA role attached to a provider that is not there
would apply cleanly and produce pods that cannot reach the bucket.

**Step 4 only matters to a root running `mode = "shared"`.**
A `dedicated` deployment can skip it entirely. Steps 3 and 4 can swap: nothing in
`products/shared-resources/*` requires the cluster.

---

## Running a stack

```bash
cd examples/aws/products/reporter/<service>

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/reporter/<service>/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

`../../../` is **three** levels up, not four. `*.tfvars` is gitignored;
`*.tfvars-example` is not.

---

## Helm handoff

Every root exports a `helm_values` map holding the **exact** env var names this
product's chart reads:

```bash
terraform output -json helm_values | jq
```

| Root | Fills in |
| --- | --- |
| `documentdb` | `MONGO_URI`, `MONGO_HOST`, `MONGO_PORT`, `MONGO_USER`, `MONGO_PARAMETERS` |
| `valkey` | `REDIS_HOST` (as `host:port`), `REDIS_TLS`, `REDIS_DB` |
| `rabbitmq` | `RABBITMQ_URI`, `RABBITMQ_HOST`, `RABBITMQ_PORT_AMQP`, `RABBITMQ_PORT_HOST`, `RABBITMQ_HEALTH_CHECK_URL`, `RABBITMQ_DEFAULT_USER` |
| `s3` | `OBJECT_STORAGE_BUCKET`, `OBJECT_STORAGE_REGION`, `OBJECT_STORAGE_ENDPOINT`, `OBJECT_STORAGE_USE_PATH_STYLE`, `OBJECT_STORAGE_DISABLE_SSL` |

> **Do not copy the midaz mapping.** Two things differ and both fail silently:
> `RABBITMQ_PORT_AMQP` is the **AMQP** port here and `RABBITMQ_PORT_HOST` is the
> **management** port — the reverse of midaz — and there is one unsuffixed
> `MONGO_*` set rather than midaz's three.

Each service README carries the full table, the destination of every key
(`configmap` versus `secrets`) and the list of keys deliberately **not** emitted.
No stack outputs a password: each exports `secret_name` and `secret_arn`, and
External Secrets Operator reads the value into the Secret the chart consumes.

---

## Dev cost

Approximate `us-east-1` on-demand, `mode = "dedicated"`, minimum sizing.

| Stack | Sizing | ~USD/month |
| --- | --- | --- |
| documentdb | `db.t3.medium`, 1 instance | 60 |
| valkey | `cache.t4g.micro`, 1 node | 12 |
| rabbitmq | `mq.m7g.medium`, SINGLE_INSTANCE | 100 |
| s3 | one bucket, dev volumes | ~0 |
| **total** | | **~172** |

RabbitMQ is the surprise. AmazonMQ offers the RabbitMQ engine only the `mq.m5.*`
and `mq.m7g.*` families; the burstable `mq.t3.micro` that would cost about
USD 20/month is **ActiveMQ-only** and is refused in every deployment mode. It is
also not optional for this product: the worker is a KEDA ScaledJob driven by
queue depth, so with no broker it never scales above zero and no report is ever
generated.

DocumentDB has no cheap corner either — `db.t3.medium` is the smallest class the
service offers. If a dev environment cannot carry both, set `mode = "shared"` on
`documentdb` and `rabbitmq`.

*Estimates. Price them against your own AWS Pricing Calculator before committing
to a size.*
