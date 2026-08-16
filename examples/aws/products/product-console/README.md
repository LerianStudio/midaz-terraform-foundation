# products/product-console

AWS datastores for **product-console**, the Next.js admin console.

One root stack, one datastore:

```
examples/aws/products/product-console/
└── documentdb/   -> _modules/mongodb-documentdb   product-console-{env}-docdb
```

---

## Why only one

From the chart discovery in
`infrastructure/IAC/product-infra-dependencies.yaml`:

```yaml
product-console:
  postgresql: no
  mongodb:    yes
  valkey:     no
  rabbitmq:   no
  redpanda:   no
```

Confirmed by reading `product-console-helm` 3.3.0 directly, because "an admin
console needs no cache" is the kind of claim that deserves evidence rather than
a shrug.

| Searched for | Patterns run | Result |
|---|---|---|
| Redis / Valkey | `REDIS`, `VALKEY`, `CACHE`, `SESSION` (and case-insensitive) | **none** — the only `cache` hits are the `nextjs-cache` `emptyDir` volume at `templates/deployment.yaml:113-119` |
| PostgreSQL | `POSTGRES`, `PG_`, `PGHOST`, `PG[A-Z]`, `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_NAME`, `DATABASE_URL` | **none** — the `DB_HOST` / `DB_PORT` hits are the optional Mongo bootstrap Job (`templates/bootstrap-mongodb.yaml:24,26`), not Postgres |
| RabbitMQ | `RABBIT`, `AMQP`, `QUEUE` | **none** |
| Kafka | `STREAMING`, `KAFKA`, `BROKER`, `REDPANDA` | **none** |
| S3 | `S3_`, `BUCKET`, `SEAWEED`, `MINIO`, `OBJECT_STORAGE` | **none** (the sibling `reporter` chart does carry these; this one does not) |

**Why no Redis is correct, not an omission:** session state is a NextAuth JWT —
`NEXTAUTH_SECRET` (`values.yaml:258`) and `NEXTAUTH_URL` (`values.yaml:204`) —
so there is no server-side session store to externalise. The Next.js build cache
is an `emptyDir`, which is per-pod by design.

### Chart dependency

| Chart dependency | Version | Repository | Turn off with |
|---|---|---|---|
| `mongodb` | 16.4.0 | charts.bitnami.com/bitnami | `mongodb.enabled: false` |

Default is `mongodb.enabled: true` (`values.yaml:270-271`). The chart's own
`values-template.yaml:111-116` spells out the DocumentDB case: *"Set to false
when using an external MongoDB (e.g. DocumentDB)."*

> There is no `mongodb.external` key in this chart, unlike midaz. `enabled:
> false` is the whole switch — and note that `secrets.MONGODB_PASS` is **not**
> wired to the subchart Secret in the first place (`templates/secrets.yaml:11-13`
> renders only literal values through `b64enc`), so the password has to be
> supplied explicitly either way.

---

## Dedicated or shared

| `mode` | What the stack does | Resources created |
|---|---|---|
| `dedicated` (default) | Creates the cluster under the product-console name, with its own security group, CMK and secret. | All of them |
| `shared` | Creates nothing. Resolves `shared-{env}-docdb` **by name** through `data "aws_rds_cluster"`, plus `shared-{env}-docdb/password` from Secrets Manager. | None |

```
dedicated   product-console-dev-docdb    product-console-dev-docdb/password
shared      shared-dev-docdb             shared-dev-docdb/password
```

DocumentDB reads through `aws_rds_cluster` because the AWS provider ships **no**
`data "aws_docdb_cluster"` at all — DocumentDB clusters are first-class DB
clusters in the RDS control plane. Verified against a real account, not inferred
from the schema.

> **This product is the best `shared` candidate in the batch.** DocumentDB's
> smallest instance class is `db.t3.medium` (~USD 60/month — there is no micro
> and no small), and the console stores UI state, not ledger data. Paying for a
> dedicated cluster per environment is hard to justify when
> `products/shared-resources/documentdb` exists.

`security_group_id` comes back `null` in shared mode: opening the shared cluster
is `products/shared-resources/documentdb`' job.

---

## Deploy order

```
1. examples/aws/bootstrap                (state bucket + lock table, per env)
2. examples/aws/infra-base/vpc           -> lerian-{env}-vpc
3. examples/aws/infra-base/eks           -> lerian-{env}-eks
4. examples/aws/products/shared-resources/documentdb   (OPTIONAL, only for mode = "shared")
5. products/product-console/documentdb
6. helm upgrade --install product-console ...
```

Step 2 is the one hard prerequisite. **Step 3 is not**: the EKS node security
group is resolved with the *plural* `data "aws_security_groups"`, which returns
an empty list instead of failing.

```bash
cd examples/aws/products/product-console/documentdb

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/product-console/documentdb/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

`../../../` is **three** levels up and lands on `examples/aws`. Verified with
`terraform init`.

`*.tfvars` is gitignored; `*.tfvars-example` is not. Copy, then edit.

---

## What gets created

With `mode = "dedicated"` and `environment = "dev"`:

| Stack | AWS resource | Secrets Manager |
|---|---|---|
| documentdb | `product-console-dev-docdb` (DocumentDB) | `product-console-dev-docdb/password` |

The AWS suffix is `docdb` and the chart variables say `MONGO`. Intentional —
`docdb` is the service, `mongodb` is what the application speaks.

---

## Helm handoff

```bash
cd examples/aws/products/product-console/documentdb
terraform output -json helm_values | jq
```

Verified against chart **product-console-helm 3.3.0** (appVersion `1.10.0`),
`values.yaml:226-233` (the `configmap:` map, rendered by
`templates/configmap.yaml:9-11`) and `values.yaml:259` (the `secrets:` map).

Everything below lands on **`.Values.configmap`**.

| Terraform | Chart env var |
|---|---|
| literal `"mongodb"` | `MONGODB_URI` |
| `endpoint` | `MONGO_HOST` |
| `port` | `MONGO_PORT` |
| `master_username` | `MONGODB_USER` |
| derived from `documentdb_tls` | `MONGO_PARAMETERS` |
| `secret_name` → External Secrets | `secrets.MONGODB_PASS` |

### This chart mixes two prefixes, and that is not a typo

Every other Lerian chart spells these `MONGO_NAME` / `MONGO_USER` /
`MONGO_PASSWORD`. product-console spells three of them **`MONGODB_DB_NAME`**,
**`MONGODB_USER`**, **`MONGODB_PASS`** while keeping `MONGO_HOST`, `MONGO_PORT`
and `MONGO_PARAMETERS` on the short prefix. The mix in `helm_values` is the
chart's own; do not "normalise" it.

Absent here but present in siblings: `MONGO_NAME`, `MONGO_USER`,
`MONGO_PASSWORD`, `MONGO_URI`, `MONGO_MAX_POOL_SIZE`, `MONGO_TLS_CA_CERT`,
`DATABASE_URL`. None of them exist in this chart.

### `MONGODB_URI` is a scheme, not a connection string

`templates/NOTES.txt:79-89` describes two modes — "full connection string" via
`MONGODB_URI`, or "host and port pair". **NOTES.txt is wrong.** No template
implements the branch: `templates/configmap.yaml:9-11` is a blind `range` over
`.Values.configmap`, and the shipped default is the bare word `mongodb`.

The application assembles:

```
{MONGODB_URI}://{MONGODB_USER}:{MONGODB_PASS}@{MONGO_HOST}:{MONGO_PORT}/{MONGODB_DB_NAME}?{MONGO_PARAMETERS}
```

`mongodb` is the only correct value for DocumentDB: it publishes no SRV records,
so `mongodb+srv` cannot resolve. Do not design against NOTES.txt.

### `MONGO_PARAMETERS`, and the `tlsInsecure` trap

`MONGO_PARAMETERS` is the DocumentDB slot, and the chart's own docs say so —
`docs/UPGRADE-2.0.md:87` introduces it *"particularly useful for connecting to
managed MongoDB services like AWS DocumentDB that require TLS."*

`helm_values` emits, with **no leading `?`** (the app appends the separator):

- `retryWrites=false` — **mandatory**. DocumentDB does not implement retryable
  writes and every driver enables them by default, so omitting it makes every
  write fail.
- `tls=true` — appended only when `documentdb_tls = "enabled"`.

The chart's documented recipe (`docs/UPGRADE-2.0.md:93`) is longer:

```yaml
MONGO_PARAMETERS: "tls=true&tlsInsecure=true&directConnection=true&retryWrites=false"
```

Two of those four are deliberately **not** emitted:

- **`tlsInsecure=true`** disables certificate validation outright. It is in the
  chart docs because the older wiring put a private CNAME in front of the
  cluster, and no validating driver could accept that name. This repository has
  no private zone — `MONGO_HOST` is the raw `*.docdb.amazonaws.com` endpoint the
  certificate covers, so validation passes on its own merits. Emitting
  `tlsInsecure` would throw that away silently.
- **`directConnection=true`** is a topology decision: correct for a
  single-instance cluster, wrong the moment `instances_count > 1`. Append it
  through `configmap.MONGO_PARAMETERS` yourself if you want it.

### `MONGODB_DB_NAME` is not emitted

The chart default is `midaz-console`. DocumentDB creates a database lazily on
first write, so Terraform never creates it and must not claim to know it. Leave
the chart default alone.

### TLS: the gap here is worse than elsewhere

The host side is already correct — `MONGO_HOST` is the raw endpoint. What is
missing is the CA bundle, and **this chart has no `MONGO_TLS_CA_CERT` variable at
all** (the sibling `reporter` and `plugin-fees` charts do). Enabling
`documentdb_tls` therefore depends on the container image already trusting the
Amazon RDS root, or on the chart gaining the variable.

`documentdb_tls` is `"disabled"` in all three environments, documented as a known
gap in `documentdb/envs/prd.tfvars-example`.

### Turning the subchart off

```yaml
mongodb:
  enabled: false     # no `external` key exists in this chart
```

Leaving it enabled deploys an in-cluster MongoDB nobody talks to. It also leaves
`mongodb.auth.rootPassword` (`values.yaml:285`) and `secrets.MONGODB_PASS`
(`values.yaml:259`) as two independent empty values you must keep consistent by
hand.

> One more chart observation, unrelated to this stack but worth knowing before a
> production install: `values.yaml:278-279` pins the subchart image to
> `bitnamisecure/mongodb:latest` — an unpinned tag. It stops mattering the moment
> `mongodb.enabled: false`, which is another argument for the external path.

---

## Secrets

No stack outputs a password. `secret_name` and `secret_arn` are outputs; the
value is read from Secrets Manager by External Secrets Operator.

| Stack | Secret (dedicated) | Secret (shared) |
|---|---|---|
| documentdb | `product-console-{env}-docdb/password` | `shared-{env}-docdb/password` |

The chart Secret carries three keys — `PLUGIN_AUTH_CLIENT_SECRET`,
`NEXTAUTH_SECRET`, `MONGODB_PASS` (`values.yaml:257-259`) — and only the last is
Terraform's business. Note `templates/secrets.yaml` uses `b64enc` over plain
values rather than `stringData`, so whatever populates it must supply raw
plaintext.

---

## Dev cost

Approximate `us-east-1` on-demand, `mode = "dedicated"`, minimum sizing:

| Stack | Sizing | ~USD/month |
|---|---|---|
| documentdb | `db.t3.medium`, 1 instance | 60 |
| **total** | | **~60** |

*These are estimates. Price them against your own AWS Pricing Calculator before
committing to a size.*

**DocumentDB has no cheap corner.** `db.t3.medium` is the smallest class the
service offers — the RDS micro/small range does not exist for it, and the module
rejects those values with a plan-time precondition rather than five minutes into
the apply. USD 60/month for an admin console's dev environment is the strongest
argument in this repository for `mode = "shared"`.
