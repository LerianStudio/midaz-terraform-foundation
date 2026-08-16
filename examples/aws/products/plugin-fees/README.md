# products/plugin-fees

AWS datastores for **plugin-fees**, the fee engine.

Two independent root stacks — one **required**, one **optional**:

```
examples/aws/products/plugin-fees/
├── documentdb/   -> _modules/mongodb-documentdb   plugin-fees-{env}-docdb    REQUIRED
└── msk/          -> _modules/streaming-msk        plugin-fees-{env}-msk      OPT-IN
```

The directory name is the **chart** name, verbatim, `plugin-` prefix included.

---

## Why these two

From the chart discovery in
`infrastructure/IAC/product-infra-dependencies.yaml`:

```yaml
plugin-fees:
  postgresql: no
  mongodb:    yes
  valkey:     no
  rabbitmq:   no
  redpanda:   yes   # optional, default off
```

Confirmed by reading `plugin-fees-helm` 7.3.0 directly. `postgres` returns only a
helper docstring; `rabbitmq`, `amqp`, `kafka`, `broker` and `redpanda` return
**zero** matches each.

| Chart dependency | Version | Repository | Turn off with |
|---|---|---|---|
| `mongodb` | 16.4.0 | charts.bitnami.com/bitnami | `mongodb.enabled: false` + `mongodb.external: true` |

That is the only declared dependency (`Chart.yaml:29-33`), default
`mongodb.enabled: true` (`values.yaml:257`).

### One correction to the discovery YAML: Valkey is not simply "no"

The YAML records `valkey: no`. That is right for the default deployment and
incomplete as a statement about the chart. plugin-fees defines **four** Redis
variables, all namespaced under `MULTI_TENANT_`:

| Variable | Where | Default |
|---|---|---|
| `MULTI_TENANT_REDIS_HOST` | `templates/fees/configmap.yaml:104` (`required`) | `""` |
| `MULTI_TENANT_REDIS_PORT` | `templates/fees/configmap.yaml:105` | `"6379"` |
| `MULTI_TENANT_REDIS_TLS` | `templates/fees/configmap.yaml:106` | `"false"` |
| `MULTI_TENANT_REDIS_PASSWORD` | `templates/fees/secrets.yaml:29` (Secret) | `""` |

All four sit inside `{{- if eq ... MULTI_TENANT_ENABLED ... "true" }}`, and
`MULTI_TENANT_ENABLED` defaults to `"false"`, so by default none render. There is
no plain `REDIS_HOST` in this chart at all.

**Consequence:** there is no `valkey/` directory here today, and turning
multi-tenancy on for plugin-fees requires adding one — copy
`products/flowker/valkey` or `products/midaz/valkey`, change the `product`
variable and its validation, and emit the `MULTI_TENANT_REDIS_*` names above
(note `HOST` and `PORT` are **split** in this family, unlike midaz's joined
`REDIS_HOST`). This mirrors `tracer`, which the same YAML annotates
"opcional, só multi-tenant".

---

## `documentdb/` — the required one

### Dedicated or shared

| `mode` | What the stack does | Resources created |
|---|---|---|
| `dedicated` (default) | Creates the cluster under the plugin-fees name, with its own security group, CMK and secret. | All of them |
| `shared` | Creates nothing. Resolves `shared-{env}-docdb` **by name** through `data "aws_rds_cluster"`, plus `shared-{env}-docdb/password`. | None |

```
dedicated   plugin-fees-dev-docdb    plugin-fees-dev-docdb/password
shared      shared-dev-docdb         shared-dev-docdb/password
```

DocumentDB reads through `aws_rds_cluster` because the AWS provider ships no
`data "aws_docdb_cluster"` at all. Verified against a real account.

### Helm handoff

Verified against **plugin-fees-helm 7.3.0** (appVersion `3.4.0`),
`templates/fees/configmap.yaml:25-34`. Everything lands on
**`.Values.fees.configmap`**.

| Terraform | Chart env var |
|---|---|
| literal `"mongodb"` | `MONGO_URI` |
| `endpoint` | `MONGO_HOST` |
| `port` | `MONGO_PORT` |
| `master_username` | `MONGO_USER` |
| derived from `documentdb_tls` | `MONGO_PARAMETERS` |
| `secret_name` → External Secrets | `MONGO_PASSWORD` |

**The unsuffixed family.** plugin-fees reads `MONGO_HOST` / `MONGO_PORT` /
`MONGO_USER` — not midaz's `MONGO_ONBOARDING_*` / `MONGO_TRANSACTION_*` pair, and
not product-console's `MONGODB_USER` hybrid. Three charts, three spellings; each
was read separately.

`MONGO_URI` is **not** a connection string. The chart ships the bare word
`mongodb` and the application assembles the URI from the surrounding variables.
`mongodb` is the only correct value for DocumentDB: it publishes no SRV records.

`MONGO_PARAMETERS` carries `retryWrites=false` — mandatory, since DocumentDB does
not implement retryable writes and every driver enables them by default — plus
`tls=true` when `documentdb_tls = "enabled"`. Emitted with no leading `?`.

> **CONFIRMAR no chart:** whether the fee engine joins `MONGO_PARAMETERS` onto the
> connection string with a leading `?` or expects one already present. The chart
> default is the empty string and no template concatenates it, so the chart
> cannot answer this. The emitted value carries no separator, matching every
> other Lerian root here.

**Not emitted:** `MONGO_NAME` (chart default `plugin-fees-db`; DocumentDB creates
databases lazily, so Terraform does not know it), `MONGO_PASSWORD` (a secret),
`MONGO_TLS_CA_CERT` (the global RDS CA bundle, which Terraform cannot
distribute), and the three pool-tuning variables.

`MONGO_USER` is emitted as the **DocumentDB master** (`docdbadmin`), not the
chart's least-privilege default `plugin-fees` — that user is created by the
chart's optional bootstrap Job
(`global.externalMongoDefinitions.enabled`, default false), not by Terraform.

### TLS

Better positioned than product-console: this chart **does** expose
`MONGO_TLS_CA_CERT` (`configmap.yaml:32`), so there is somewhere to mount the
global RDS bundle. Terraform does not distribute that bundle, so flipping
`documentdb_tls` to `"enabled"` is a two-sided change. Left `"disabled"` in all
three environments, documented in `documentdb/envs/prd.tfvars-example`.

### Turning the subchart off

```yaml
mongodb:
  enabled:  false
  external: true
```

`external: true` is what moves `MONGO_PASSWORD` off the Bitnami subchart Secret
(`templates/deployment.yaml:61`, helper `_helpers.tpl:165-180`) and onto the
chart's own — otherwise the credentials Terraform wrote are silently ignored.

---

## `msk/` — the optional one

### Do not apply this directory by reflex

**Streaming is off by default.** `STREAMING_ENABLED` renders `"false"`
(`templates/fees/configmap.yaml:120`) and the key is not even present in
`values.yaml`.

**And MSK has no cheap corner.** `kafka.t3.small` is the smallest broker AWS
offers, the minimum is two brokers, and `number_of_broker_nodes` must be a
**multiple of the number of client subnets**. `infra-base/vpc` tags three subnets
`Type=database`, so the valid values are 3, 6, 9 — three brokers is the real
floor, roughly **USD 105/month**. A 2-broker cluster needs `subnet_ids` narrowed
to exactly two ids, which cannot be written into a `tfvars-example` because the
ids are generated.

### The normal path is `mode = "shared"`

All three `msk/envs/*.tfvars-example` ship `mode = "shared"`, overriding the
variable default (`"dedicated"`, kept only so this root behaves like every other
product root).

| `mode` | What the stack does | Resources created |
|---|---|---|
| `shared` **(what the tfvars ship)** | Creates nothing. Resolves `shared-{env}-msk` through `data "aws_msk_cluster"`, plus `AmazonMSK_shared-{env}-msk`. | None |
| `dedicated` | Creates `plugin-fees-{env}-msk`, its security group, its CMKs and its secret. | All of them |

A fee engine emitting CloudEvents is a low-volume publisher; a dedicated
three-broker cluster for it is hard to justify against a shared tier that already
exists. `msk/envs/prd.tfvars-example` lists the three conditions that would
justify switching.

In shared mode `products/shared-resources/msk` must be applied **first**:
`data "aws_msk_cluster"` is singular and fails the plan when it does not match,
naming the cluster it looked for. That is the desired behaviour — an unresolvable
shared cluster must stop the apply rather than emit a null broker list into the
Helm values.

`security_group_id` comes back `null`: a product in shared mode creates no
security group and cannot authorise itself. Opening the shared cluster is
`products/shared-resources/msk`' job.

### Helm handoff — and the gap in it

Verified against **plugin-fees-helm 7.3.0**, `templates/fees/configmap.yaml:119-126`
and `templates/fees/secrets.yaml:35-39`. The chart defines eight `STREAMING_*`
ConfigMap keys and two Secret keys; that is the complete set.

| Terraform | Chart env var |
|---|---|
| literal `"true"` | `STREAMING_ENABLED` |
| derived from `encryption_in_transit_client_broker` | `STREAMING_TLS_ENABLED` |
| `scram_username` | `STREAMING_SASL_USERNAME` |
| literal `"false"` | `STREAMING_SASL_ALLOW_PLAINTEXT` |
| `endpoint` (bootstrap broker list) | `STREAMING_BROKERS` — **see below** |
| `secret_name` → External Secrets | `STREAMING_SASL_PASSWORD` |

#### `STREAMING_BROKERS` does not exist in this chart

The same gap midaz has, **checked independently rather than assumed**. Grep for
`STREAMING` across plugin-fees-helm 7.3.0 returns exactly thirteen hits — eight
ConfigMap keys, two Secret keys, three `values.yaml` entries — and grep for
`broker` and for `kafka` returns **zero**.

The chart can turn streaming on and configure its TLS and its SASL, and has
nowhere to put a broker address. So `STREAMING_BROKERS` must be injected through
**`fees.extraEnvVars`** until the chart grows the variable. It is emitted under
that name because that is what the `streaming-msk` module README already uses, so
the day the chart adds it the wiring is a rename, not a rediscovery.

#### `STREAMING_SASL_MECHANISM` is omitted — the one open `CONFIRMAR`

MSK implements **SCRAM-SHA-512 and nothing else**. That half is settled. What is
not verifiable from the chart is the *spelling* the Lerian streaming client
accepts: `configmap.yaml:123` renders the key with an empty default, and no
template, values file or `values.schema.json` in 7.3.0 enumerates accepted
strings.

`SCRAM-SHA-512` vs `scram-sha-512` vs `SCRAM_SHA_512` is a coin flip whose losing
side is an authentication failure nobody would look for in a Terraform output. So
Terraform does not guess: `var.streaming_sasl_mechanism` defaults to `""`, which
**omits the key**.

Confirm it against `lib-streaming`, set the variable once, and the handoff is
complete. `msk/envs/prd.tfvars-example` flags it as required before the first
production release with streaming on.

#### A chart bug that affects TLS wiring

`templates/fees/deployment.yaml:51-55` lists `envFrom` as `secretRef` **first**
and `configMapRef` **second**. In Kubernetes the later source wins on a duplicate
key — and `STREAMING_TLS_CA_CERT` is defined in **both**
(`configmap.yaml:125`, `secrets.yaml:39`). The ConfigMap always renders it, with
a default of five literal spaces, so it silently overwrites whatever an operator
puts in the Secret.

This does not affect the MSK wiring as shipped (the public Amazon trust store
already covers MSK broker certificates, so nothing needs distributing), but if a
CA bundle is ever required it has to go in the ConfigMap copy or through
`extraEnvVars`. `MONGO_PASSWORD` is unaffected — it is injected through the
container `env:` list, which outranks all `envFrom`.

**Reported, not worked around.** Terraform cannot fix `envFrom` ordering.

---

## Deploy order

```
1. examples/aws/bootstrap                (state bucket + lock table, per env)
2. examples/aws/infra-base/vpc           -> lerian-{env}-vpc
3. examples/aws/infra-base/eks           -> lerian-{env}-eks
4. examples/aws/products/shared-resources/{documentdb,msk}   (OPTIONAL; REQUIRED for any mode = "shared")
5. products/plugin-fees/documentdb   and   products/plugin-fees/msk   <- in any order, in parallel
6. helm upgrade --install plugin-fees ...
```

The two roots in step 5 have **no dependency on each other**: separate state
files, separate locks, separate blast radius.

Step 4 is mandatory for `msk/` as shipped, because the tfvars set
`mode = "shared"`.

```bash
cd examples/aws/products/plugin-fees/documentdb
terraform init -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/plugin-fees/documentdb/terraform.tfstate"

cd examples/aws/products/plugin-fees/msk
terraform init -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/plugin-fees/msk/terraform.tfstate"
```

`../../../` is **three** levels up and lands on `examples/aws`. Verified with
`terraform init`.

State keys:

| Stack | State key |
|---|---|
| documentdb | `aws/products/plugin-fees/documentdb/terraform.tfstate` |
| msk | `aws/products/plugin-fees/msk/terraform.tfstate` |

`*.tfvars` is gitignored; `*.tfvars-example` is not.

---

## Secrets

No stack outputs a password.

| Stack | Secret (dedicated) | Secret (shared) |
|---|---|---|
| documentdb | `plugin-fees-{env}-docdb/password` | `shared-{env}-docdb/password` |
| msk | `AmazonMSK_plugin-fees-{env}-msk` | `AmazonMSK_shared-{env}-msk` |

The MSK secret carries the AWS-mandated `AmazonMSK_` prefix rather than the usual
`{name}/password` path, and AWS requires it to be encrypted with a customer
managed CMK. Both are service constraints, not Lerian conventions.

---

## Dev cost

Approximate `us-east-1` on-demand, minimum sizing:

| Stack | Mode | Sizing | ~USD/month |
|---|---|---|---|
| documentdb | dedicated | `db.t3.medium`, 1 instance | 60 |
| msk | **shared** | — | 0 (the shared tier's cost, if it exists) |
| msk | *dedicated, if you switch* | `kafka.t3.small` × 3 | *105* |
| **total as shipped** | | | **~60** |

*These are estimates. Price them against your own AWS Pricing Calculator before
committing to a size.*

**DocumentDB has no cheap corner:** `db.t3.medium` is the smallest class the
service offers — the RDS micro/small range does not exist for it, and the module
rejects those values with a plan-time precondition rather than five minutes into
the apply. If a dev environment cannot carry USD 60, set `mode = "shared"` on the
documentdb root too.

**MSK is the reason `msk/envs/*` ship `shared`:** switching that one variable to
`dedicated` nearly triples the product's dev bill, for a feature the chart ships
turned off.
