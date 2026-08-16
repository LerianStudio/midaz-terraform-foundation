# products/plugin-br-bank-transfer

AWS datastores for the **plugin-br-bank-transfer** product: Brazilian bank
transfer (TED) over the JD-SPB rail.

Four independent root stacks, one per datastore:

```
examples/aws/products/plugin-br-bank-transfer/
├── postgres/     -> _modules/postgres-rds         plugin-br-bank-transfer-{env}-postgres
├── documentdb/   -> _modules/mongodb-documentdb   plugin-br-bank-transfer-{env}-docdb
├── valkey/       -> _modules/valkey-elasticache   plugin-br-bank-transfer-{env}-valkey
└── rabbitmq/     -> _modules/rabbitmq-amazonmq    plugin-br-bank-transfer-{env}-rabbitmq   (OPTIONAL)
```

The directory name is the chart name, `plugin-` prefix included. Everything
structural — the `lerian-{env}-vpc` / `lerian-{env}-eks` derivations, the
`shared-{env}-*` resolution of the shared tier, the ingress model, the `check`
block, the provider and backend blocks — is identical to
[`products/midaz`](../midaz/README.md) and is not re-explained here.

---

## Why these four, and why one of them is optional

From the chart discovery in `infrastructure/IAC/product-infra-dependencies.yaml`:

```yaml
plugin-br-bank-transfer:
  postgresql: yes
  mongodb:    yes
  valkey:     yes
  rabbitmq:   yes        # declarado off por default, esperado externo
  redpanda:   no
```

Reading the chart confirms the first three as hard, always-on dependencies, and
sharpens the fourth. `Chart.yaml` declares four Bitnami/groundhog2k subcharts:

| Chart dependency | Version | Repository | Default | Turn off with |
|---|---|---|---|---|
| `postgresql` | 16.3.5 | charts.bitnami.com/bitnami | `enabled: true` | `postgresql.enabled: false` + `postgresql.external: true` |
| `mongodb` | 16.4.12 | charts.bitnami.com/bitnami | `enabled: true` | `mongodb.enabled: false` + `mongodb.external: true` |
| `valkey` | 2.4.7 | registry-1.docker.io/bitnamicharts | `enabled: true` | `valkey.enabled: false` + `valkey.external: true` |
| `rabbitmq` | 2.1.11 | groundhog2k.github.io/helm-charts | **`enabled: false`** | already off |

> **Both `enabled` and `external` matter** for postgresql, mongodb and valkey.
> `enabled: false` stops the subchart from deploying; `external: true` is what
> moves credential resolution off the subchart's Secret and onto the chart's own.
> `templates/deployment.yaml` and `templates/secrets.yaml` branch on exactly
> that flag. Setting only the first leaves the deployment reading a Secret that
> no longer exists.

### RabbitMQ is off on **two** switches, not one

The YAML's note ("declarado off por default, esperado externo") is right but
understates it. There are two independent switches and both ship off:

```yaml
rabbitmq:
  enabled: false                    # Chart.yaml dependency — no bundled broker
bankTransfer:
  configmap:
    RABBITMQ_ENABLED: "false"       # the application's own client switch
```

and `templates/configmap.yaml` renders `RABBITMQ_URL` and `RABBITMQ_EXCHANGE`
**only** inside `{{- if eq (toString ... RABBITMQ_ENABLED) "true" }}`. So the
event bus is genuinely optional: with the defaults, the plugin never opens an
AMQP connection at all.

That matters because the broker is the most expensive datastore of the four —
an AmazonMQ RabbitMQ floor of roughly USD 100/month, comparable to the
DocumentDB cluster and more than PostgreSQL and Valkey combined. **Applying
`rabbitmq/` is a decision.** If the event bus is not needed in an environment,
do not apply that directory; "not applied" is what "off" means in this
repository, and there is no `rabbitmq_enabled` toggle to forget.

`helm_values` in that root emits `RABBITMQ_ENABLED = "true"` for exactly this
reason: applying the directory *is* the decision that flips it.

---

## Single-tenant and multi-tenant render different ConfigMaps

`templates/configmap.yaml` computes

```
$multiTenantEnabled := (bankTransfer.configmap.MULTI_TENANT_ENABLED == "true")
```

and wraps the **entire** `POSTGRES_*`, `MONGO_*` and `RABBITMQ_*` blocks in
`{{- if not $multiTenantEnabled }}`. With multi-tenancy on, the plugin resolves
per-tenant databases through the tenant-manager and per-tenant credentials
through AWS Secrets Manager, and those keys are simply not rendered.

What that means for these roots:

| Block | single-tenant | multi-tenant |
|---|---|---|
| `POSTGRES_*` | rendered | **not rendered** |
| `MONGO_*` | rendered | **not rendered** |
| `RABBITMQ_*` | rendered (when enabled) | **not rendered** |
| `REDIS_HOST` / `REDIS_DB` / `REDIS_TLS` | rendered | rendered (tuning keys are not) |
| `MULTI_TENANT_REDIS_HOST` / `_PORT` / `_TLS` | not rendered | rendered, and `_HOST` is `required()` |

Merging `helm_values` into a multi-tenant release is harmless — the keys are
just not read — but it is not what wires the datastores. The Valkey root is the
one whose output matters in both modes, which is why it emits both the plain and
the `MULTI_TENANT_` variants.

---

## Helm handoff

Verified against chart **1.5.0** (appVersion 1.2.1), `templates/configmap.yaml`,
`templates/secrets.yaml`, `templates/deployment.yaml`,
`templates/migration-secret.yaml` and `templates/_helpers.tpl`.

### postgres → `bankTransfer.configmap`

| Terraform | Chart key |
|---|---|
| `endpoint` | `POSTGRES_HOST` |
| `port` | `POSTGRES_PORT` |
| `username` | `POSTGRES_USER` |
| `database_name` | **`POSTGRES_DB`** |
| `replica_endpoint` (only when a replica exists) | `POSTGRES_REPLICA_HOST` |
| `port` / `username` / `database_name` | `POSTGRES_REPLICA_PORT` / `_USER` / `_DB` |
| `secret_name` → External Secrets | `POSTGRES_PASSWORD`, `POSTGRES_REPLICA_PASSWORD` |

> **`POSTGRES_DB`, not `POSTGRES_NAME`.** Three Lerian charts, three spellings of
> the same idea: `POSTGRES_DB` here, `POSTGRES_NAME` in notifications,
> `DB_ONBOARDING_NAME` / `DB_TRANSACTION_NAME` in midaz. There is no shared
> convention to lean on.

The replica keys appear **only** when `create_read_replica = true`, because the
chart renders that whole block only when `POSTGRES_REPLICA_HOST` is set. Unset
means "no CQRS read pool", which is the right shape for a single instance — this
root does not copy the midaz trick of pointing the replica variables back at the
primary.

`POSTGRES_SSLMODE` is not emitted: client policy, and the chart default is
already `require`.

One extra requirement the chart imposes on the external path: when
`migrations.enabled` is true and PostgreSQL is external,
`bankTransfer.secrets.POSTGRES_PASSWORD` must be non-empty or the render fails —
the helper `bank-transfer.migrationPostgresPassword` calls `required()` on it,
because the migration Job runs as a `pre-install` hook and needs its credential
before the application Secret exists.

### documentdb → `bankTransfer.secrets`

This chart has **no `MONGO_HOST` and no `MONGO_PORT`.** The plugin is URI-only;
the single connection setting is `MONGO_URI`, and it lives in the Secret.

| Terraform | Chart key |
|---|---|
| `mongo_uri` (see below) | `MONGO_URI` |
| `secret_name` → External Secrets | `MONGO_PASSWORD` |

The emitted URI keeps the password out of Terraform state by using the chart's
own mechanism:

```
mongodb://docdbadmin:$(MONGO_PASSWORD)@<writer-endpoint>:27017/?authSource=admin&retryWrites=false
```

`$(MONGO_PASSWORD)` is **Kubernetes env expansion**, not Terraform
interpolation. `templates/_helpers.tpl` (`bank-transfer.mongoEnv`) emits
`MONGO_URI` as an explicit `env:` entry with a `value:`, immediately after a
`MONGO_PASSWORD` entry sourced with `secretKeyRef`, and the kubelet expands
`$(VAR)` in env values against earlier entries in the same list. The credential
travels Secrets Manager → Secret → container and never touches Terraform.

`retryWrites=false` is **mandatory**: DocumentDB does not implement retryable
writes, every modern driver enables them by default, and the chart's own
bundled-Mongo URI does not carry it (correct for real MongoDB, fatal here).

> **The external path is a cliff, not a slope.** With `mongodb.enabled: false`
> and **no** `bankTransfer.secrets.MONGO_URI`, `mongoEnv` emits **no `MONGO_URI`
> env at all**. The deployment renders cleanly and the plugin starts with no
> connection string; there is no `required()` guarding it. Setting
> `bankTransfer.secrets.MONGO_URI` from this output is therefore mandatory, not
> optional. `bankTransfer.secrets.MONGO_PASSWORD` must be set too — it is what
> makes `mongoEnv` emit the `MONGO_PASSWORD` env that the expansion needs.

`MONGO_DATABASE` is not emitted: DocumentDB creates a database lazily on first
write, so Terraform never creates it and must not claim to know it. (The chart
is internally inconsistent here anyway — `MONGO_DATABASE` defaults to
`plugin_br_bank_transfer` while the bundled subchart provisions
`plugin_br_bank_transfer_jd`.)

### valkey → `bankTransfer.configmap`

| Terraform | Chart key |
|---|---|
| `"${endpoint}:${port}"` | **`REDIS_HOST`** |
| `redis_db_index` | `REDIS_DB` |
| derived from `transit_encryption_mode` | `REDIS_TLS` |
| `endpoint` / `port`, **split** | `MULTI_TENANT_REDIS_HOST` / `MULTI_TENANT_REDIS_PORT` |
| `secret_name` → External Secrets | `REDIS_PASSWORD`, `MULTI_TENANT_REDIS_PASSWORD` |

> **`REDIS_HOST` carries `host:port`.** There is no `REDIS_PORT` key in this
> chart. The proof is not the default value alone — it is the init container in
> `templates/deployment.yaml`, which splits the variable itself:
>
> ```sh
> REDIS_SVC=$(echo "$REDIS_HOST" | cut -d: -f1)
> REDIS_PORT_NUM=$(echo "$REDIS_HOST" | cut -d: -f2)
> wait_for_service "$REDIS_SVC" "$REDIS_PORT_NUM"
> ```
>
> A bare hostname makes that `cut` return the hostname twice and the readiness
> gate dials the host as if it were a port. This matches the **midaz** chart and
> not the **notifications** chart, which keeps `REDIS_PORT` separate. Each chart
> has to be read.
>
> The `MULTI_TENANT_REDIS_*` pair is split even here — the shape flips inside a
> single ConfigMap.

`REDIS_USER` exists in the chart but is **not** emitted:

> **CONFIRMAR no chart:** the chart renders `REDIS_USER` only when the operator
> sets it, and this repository configures no ElastiCache RBAC user. The implicit
> ElastiCache account is `default`, but whether the plugin needs `REDIS_USER` at
> all against an auth-token (non-RBAC) ElastiCache is a question for the plugin
> team. Not emitted until confirmed.

### rabbitmq → `bankTransfer.configmap`

| Terraform | Chart key |
|---|---|
| applying the directory | `RABBITMQ_ENABLED = "true"` |
| **not emitted** | `RABBITMQ_URL` |

`RABBITMQ_URL` is the only connection variable this chart has — no host, no
port, no user key — and it embeds the credentials. Terraform building it would
write a cleartext password into state.

The escape hatch that works for this product's MongoDB does **not** work here,
and the reason is worth spelling out because the chart itself gets it wrong:

| | delivery | `$(VAR)` expanded? |
|---|---|---|
| `MONGO_URI` | explicit `env:` entry with `value:` | **yes** — kubelet expands against earlier `env` entries |
| `RABBITMQ_URL` | ConfigMap key, delivered with `envFrom:` | **no** — Kubernetes never expands envFrom values |

The chart's own default for `RABBITMQ_URL` is
`amqp://bank_transfer:$(RABBITMQ_PASSWORD)@<release>-rabbitmq...`, placed in the
ConfigMap. That placeholder cannot be expanded from there, so the literal string
`$(RABBITMQ_PASSWORD)` reaches the application — **even on the bundled-subchart
path**. See "Findings for the chart owners" below.

Assemble the URL in the secret store from `secret_name` plus the `amqp_endpoint`
output, and note the scheme must be `amqps`:

```
amqp_endpoint  ->  amqps://host:5671
RABBITMQ_URL   ->  amqps://USER:URLENCODED_PW@host:5671/
```

AmazonMQ publishes **no plaintext AMQP listener**, so the chart default's `amqp`
scheme cannot connect at all. Also mind the `envFrom` ordering in
`templates/deployment.yaml`: `secretRef` comes **before** `configMapRef`, so a
ConfigMap key of the same name wins over a Secret key. Override
`bankTransfer.configmap.RABBITMQ_URL` (or use `bankTransfer.extraEnvVars`),
not just the Secret.

`RABBITMQ_EXCHANGE` is application topology, not infrastructure.

---

## Findings for the chart owners

Recorded here because they were found while reading the chart to build these
roots, and they are not things this stack can fix.

1. **`RABBITMQ_URL`'s `$(RABBITMQ_PASSWORD)` placeholder cannot work.** It is a
   ConfigMap value delivered by `envFrom`, and Kubernetes expands `$(VAR)` only
   in `env[].value`. The MongoDB sibling gets this right by emitting `MONGO_URI`
   as an explicit `env` entry; RabbitMQ does not.
2. **External MongoDB with no `MONGO_URI` override renders a pod with no Mongo
   connection string at all**, silently. `MONGO_HOST` has a `required()` guard in
   the sibling `plugin-br-pix-indirect-btg` chart; this one has none for
   `MONGO_URI`.
3. **`MONGO_DATABASE` and the bundled subchart disagree**:
   `plugin_br_bank_transfer` versus `plugin_br_bank_transfer_jd`.
4. **`files/rabbitmq/load_definition.json`** seeds exchanges, queues and
   bindings into the bundled broker through
   `management.load_definitions`. **AmazonMQ does not accept a definitions
   file**, so on the managed path that topology has to be created some other way.
   > **CONFIRMAR com o time:** what creates the exchanges and queues when the
   > broker is AmazonMQ.
5. The bundled `postgresql` subchart pins image `bitnami/postgresql:17.4.0`
   while these roots provision RDS PostgreSQL **16** (the repo-wide major, kept
   MAJOR-only on purpose). Nothing observed in the chart requires 17.
   > **CONFIRMAR com o time:** whether the plugin needs any PostgreSQL 17
   > feature. If it does, `engine_version`, `family` and `major_engine_version`
   > move together to `"17"` / `"postgres17"` / `"17"`.

---

## Deploy order

```
1. examples/aws/bootstrap                (state bucket + lock table, per env)
2. examples/aws/infra-base/vpc           -> lerian-{env}-vpc
3. examples/aws/infra-base/eks           -> lerian-{env}-eks
4. examples/aws/products/shared-resources/*  (OPTIONAL, only for mode = "shared")
5. products/plugin-br-bank-transfer/{postgres,documentdb,valkey}   <- in parallel
   ...and rabbitmq/ ONLY if the event bus is being used
6. helm upgrade --install plugin-br-bank-transfer ...
```

State keys:

| Stack | State key |
|---|---|
| postgres | `aws/products/plugin-br-bank-transfer/postgres/terraform.tfstate` |
| documentdb | `aws/products/plugin-br-bank-transfer/documentdb/terraform.tfstate` |
| valkey | `aws/products/plugin-br-bank-transfer/valkey/terraform.tfstate` |
| rabbitmq | `aws/products/plugin-br-bank-transfer/rabbitmq/terraform.tfstate` |

```bash
cd examples/aws/products/plugin-br-bank-transfer/postgres

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/plugin-br-bank-transfer/postgres/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

---

## What gets created

With `mode = "dedicated"` and `environment = "dev"`:

| Stack | AWS resource | Secrets Manager |
|---|---|---|
| postgres | `plugin-br-bank-transfer-dev-postgres` (RDS) | `plugin-br-bank-transfer-dev-postgres/password` |
| documentdb | `plugin-br-bank-transfer-dev-docdb` (DocumentDB) | `plugin-br-bank-transfer-dev-docdb/password` |
| valkey | `plugin-br-bank-transfer-dev-valkey` (ElastiCache) | `plugin-br-bank-transfer-dev-valkey/auth-token` |
| rabbitmq | `plugin-br-bank-transfer-dev-rabbitmq-single` (AmazonMQ) | `plugin-br-bank-transfer-dev-rabbitmq/password` |

---

## Dev cost

Approximate `us-east-1` on-demand, `mode = "dedicated"`, minimum sizing:

| Stack | Sizing | ~USD/month |
|---|---|---|
| postgres | `db.t4g.micro`, 20 GB | 15 |
| valkey | `cache.t4g.micro`, 1 node | 12 |
| documentdb | `db.t3.medium`, 1 instance | 60 |
| **subtotal (required)** | | **~87** |
| rabbitmq (OPTIONAL) | `mq.m7g.medium`, SINGLE_INSTANCE | 100 |
| **total with the event bus** | | **~187** |

*Estimates. Price them against your own AWS Pricing Calculator before committing
to a size.*

Two datastores have no cheap corner:

- **DocumentDB.** `db.t3.medium` is the smallest class the service offers; the
  RDS micro/small range does not exist for it, and the module rejects those
  values with a plan-time precondition.
- **AmazonMQ RabbitMQ.** Only the `mq.m5.*` and `mq.m7g.*` families are
  accepted. `mq.t3.micro` (~USD 20/month) is **ActiveMQ-only** and AmazonMQ
  refuses it for RabbitMQ in every deployment mode. Dev's only lever is
  `SINGLE_INSTANCE`.

For either one, `mode = "shared"` on that root consumes the corresponding
`products/shared-resources/<service>` instead of paying twice.
