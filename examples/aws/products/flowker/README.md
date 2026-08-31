# products/flowker

AWS datastores for **flowker**, the low-code orchestration engine.

Two independent root stacks:

```
examples/aws/products/flowker/
├── documentdb/   -> _modules/mongodb-documentdb   flowker-{env}-docdb
└── valkey/       -> _modules/valkey-elasticache   flowker-{env}-valkey
```

---

## READ THIS FIRST: the composition here is INFERRED, and the Helm handoff is EMPTY

Every other product directory in this repository derives its datastore list, and
its `helm_values` map, from a chart it can read. **flowker has no readable
chart.**

`infrastructure/K8S/helm/charts/flowker/` contains exactly two files:

```
flowker/
└── charts/
    ├── mongodb-16.4.0.tgz     Bitnami — byte-identical to plugin-fees' copy
    └── valkey-0.7.4.tgz       valkey-io/valkey-helm, upstream
```

No `Chart.yaml`. No `values.yaml`. No `values-template.yaml`. No `templates/`.
No `Chart.lock`. No `README.md`. `helm template` against that directory fails on
the missing `Chart.yaml`. What is there is the residue of a
`helm dependency build` whose parent chart was never committed.

### What that does and does not license

**The infrastructure is well founded.** Two vendored datastore subcharts is
unambiguous evidence that flowker runs on a MongoDB and a Valkey, and it agrees
with the automated discovery in
`infrastructure/IAC/product-infra-dependencies.yaml`:

```yaml
flowker:               # inferido (sem Chart.yaml)
  postgresql: no
  mongodb:    yes
  valkey:     yes
  rabbitmq:   no
  redpanda:   no
```

So both directories exist and both produce correct AWS resources. Endpoints,
ports, secrets, security groups, subnet placement — none of that depends on the
chart.

**The chart contract is not founded at all.** Both tarballs were extracted and
read. The only literal environment variables inside them are:

- the Bitnami `MONGODB_*` family (`MONGODB_ROOT_USER`, `MONGODB_PORT_NUMBER`,
  `MONGODB_REPLICA_SET_MODE`, …), which configures the MongoDB **pod** and is
  meaningless once the datastore is DocumentDB;
- a single `VALKEY_LOGLEVEL`, likewise for the Valkey pod.

Searching the extracted trees for `MONGO_` (single word), `REDIS_`, `POSTGRES`,
`RABBIT`, `AMQP`, `STREAMING_`, `KAFKA` and `BROKER` returns **zero** matches.
Not one flowker-side variable name appears anywhere.

### Therefore `helm_values` is `{}` in both roots

This is the only empty `helm_values` in the repository, and it is deliberate.

Guessing `MONGO_HOST` / `REDIS_HOST` because sibling charts use them would be the
most damaging thing these files could do: it looks verified, it reviews clean,
and it produces a release that never connects. The charts read alongside flowker
in this batch make the point by contradiction:

| Chart | Mongo host variable | Redis host variable |
|---|---|---|
| midaz | `MONGO_ONBOARDING_HOST`, `MONGO_TRANSACTION_HOST` | `REDIS_HOST` carrying **`host:port` joined**, plus `MULTI_TENANT_REDIS_HOST`/`_PORT` **split** |
| product-console | `MONGO_HOST` + `MONGODB_USER` + `MONGODB_DB_NAME` | none at all |
| plugin-fees | `MONGO_HOST` | `MULTI_TENANT_REDIS_HOST`/`_PORT`, split, only when multi-tenancy is on |

Three charts, three Mongo spellings — and midaz contradicts *itself* between two
Redis families in the same file. There is no convention to fall back on.

### What to do instead

The endpoints are published as ordinary outputs and are correct:

```bash
cd examples/aws/products/flowker/documentdb
terraform output endpoint port master_username secret_name

cd examples/aws/products/flowker/valkey
terraform output endpoint port transit_encryption_required secret_name
```

Join `endpoint` and `port` for a chart that wants `host:port`; use them
separately for one that splits them. Hand these to the team that owns flowker.

**When the chart lands in this monorepo**, fill in the `helm_values` map in each
`outputs.tf` from *flowker's own* `values.yaml` and templates — never from a
sibling's — and delete this section.

### Open questions for the service owner

| Question | Why it matters here |
|---|---|
| What are the Mongo and Valkey env var names? | Blocks `helm_values` in both roots. |
| Does the Valkey client speak TLS, and does it send `AUTH`? | `transit_encryption_mode` stays `"preferred"` and `auth_token_enabled` stays `false` because neither can be confirmed. The token *is* generated and stored either way. |
| Does the Mongo client trust the Amazon RDS root CA? | `documentdb_tls` stays `"disabled"` for the same reason. Elsewhere that gap has a named blocker; here it is simply unassessable. |
| Is Valkey used for **distributed locks** or only for caching? | If locks, node count and failover stop being a performance question and become a correctness one — see `valkey/envs/prd.tfvars-example`. |
| What is the real workload profile? | The prd sizings are the standard Lerian shape, not a measurement. Orchestration engines are bursty writers, which is a different instance-class question from a read-heavy console. |

---

## Dedicated or shared

Both roots take `mode`:

| `mode` | What the stack does | Resources created |
|---|---|---|
| `dedicated` (default) | Creates the datastore under the flowker name, with its own security group and secret. | All of them |
| `shared` | Creates nothing. Resolves the datastore owned by the matching `products/shared-resources/<service>` root **by name**, plus its secret. | None |

```
dedicated   flowker-dev-docdb     flowker-dev-docdb/password
shared      shared-dev-docdb      shared-dev-docdb/password

dedicated   flowker-dev-valkey    flowker-dev-valkey/auth-token
shared      shared-dev-valkey     shared-dev-valkey/auth-token
```

| Module | Data source | Name resolved |
|---|---|---|
| `mongodb-documentdb` | `aws_rds_cluster` | `shared-{env}-docdb` |
| `valkey-elasticache` | `aws_elasticache_replication_group` | `shared-{env}-valkey` |

DocumentDB reads through `aws_rds_cluster` because the AWS provider ships no
`data "aws_docdb_cluster"` at all — DocumentDB clusters are first-class DB
clusters in the RDS control plane. Verified against a real account.

`security_group_id` comes back `null` in shared mode: opening the shared
datastore is the `products/shared-resources/<service>` root's job.

---

## Deploy order

```
1. examples/aws/bootstrap                (state bucket + lock table, per env)
2. examples/aws/infra-base/vpc           -> lerian-{env}-vpc
3. examples/aws/infra-base/eks           -> lerian-{env}-eks
4. examples/aws/products/shared-resources/{documentdb,valkey}   (OPTIONAL, only for mode = "shared")
5. products/flowker/documentdb   and   products/flowker/valkey   <- in any order, in parallel
6. helm upgrade --install flowker ...    (blocked on the chart — see above)
```

Step 2 is the one hard prerequisite. **Step 3 is not**: the EKS node security
group is resolved with the *plural* `data "aws_security_groups"`, which returns
an empty list instead of failing.

The two roots in step 5 have **no dependency on each other**: separate state
files, separate locks, separate blast radius.

```bash
cd examples/aws/products/flowker/documentdb
terraform init -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/flowker/documentdb/terraform.tfstate"

cd examples/aws/products/flowker/valkey
terraform init -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/flowker/valkey/terraform.tfstate"
```

`../../../` is **three** levels up and lands on `examples/aws`, where both
`backend/` and `_modules/` live. Verified with `terraform init`.

State keys:

| Stack | State key |
|---|---|
| documentdb | `aws/products/flowker/documentdb/terraform.tfstate` |
| valkey | `aws/products/flowker/valkey/terraform.tfstate` |

`*.tfvars` is gitignored; `*.tfvars-example` is not. Copy, then edit.

---

## What gets created

With `mode = "dedicated"` and `environment = "dev"`:

| Stack | AWS resource | Secrets Manager |
|---|---|---|
| documentdb | `flowker-dev-docdb` (DocumentDB) | `flowker-dev-docdb/password` |
| valkey | `flowker-dev-valkey` (ElastiCache) | `flowker-dev-valkey/auth-token` |

The AWS suffix is `docdb` and the application speaks `mongodb`. Intentional —
`docdb` is the service, `mongodb` is the protocol.

---

## There is no private DNS layer

No stack here creates a CNAME, and there is no `{env}.lerian.internal` zone.
Every AWS datastore presents a certificate for its **own** service domain —
DocumentDB `*.docdb.amazonaws.com`, ElastiCache
`*.{cluster}.{region}.cache.amazonaws.com` — so a private alias in front of
either breaks TLS hostname verification for every client that validates it.

Both roots therefore export `endpoint`, the raw AWS host, in both modes.

---

## Secrets

No stack outputs a password. Each outputs `secret_name` and `secret_arn`; the
value is read from Secrets Manager by External Secrets Operator.

| Stack | Secret (dedicated) | Secret (shared) |
|---|---|---|
| documentdb | `flowker-{env}-docdb/password` | `shared-{env}-docdb/password` |
| valkey | `flowker-{env}-valkey/auth-token` | `shared-{env}-valkey/auth-token` |

**Which chart key each should be projected into is unknown** — see the top of
this file. The Valkey auth token is generated and stored whether or not
ElastiCache enforces it, so enabling enforcement later is a tfvars change plus a
chart change, not a rebuild.

---

## Dev cost

Approximate `us-east-1` on-demand, `mode = "dedicated"`, minimum sizing:

| Stack | Sizing | ~USD/month |
|---|---|---|
| documentdb | `db.t3.medium`, 1 instance | 60 |
| valkey | `cache.t4g.micro`, 1 node | 12 |
| **total** | | **~72** |

*These are estimates. Price them against your own AWS Pricing Calculator before
committing to a size.*

**DocumentDB has no cheap corner:** `db.t3.medium` is the smallest class the
service offers — the RDS micro/small range does not exist for it, and the module
rejects those values with a plan-time precondition rather than five minutes into
the apply. If a dev environment cannot carry that, set `mode = "shared"` on the
documentdb root.

Given that this product cannot be wired to a chart yet, `mode = "shared"` on both
roots is the sensible posture until the chart exists: it costs nothing and still
proves the network path.
