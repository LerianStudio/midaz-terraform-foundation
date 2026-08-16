# products/notifications

AWS datastores for the **notifications** product: multi-channel delivery (email,
SMS, webhook) for the Lerian platform.

Three independent root stacks, one per datastore:

```
examples/aws/products/notifications/
├── postgres/     -> _modules/postgres-rds         notifications-{env}-postgres
├── valkey/       -> _modules/valkey-elasticache   notifications-{env}-valkey
└── rabbitmq/     -> _modules/rabbitmq-amazonmq    notifications-{env}-rabbitmq
```

Everything structural — the `lerian-{env}-vpc` / `lerian-{env}-eks` derivations,
the `shared-{env}-*` resolution of the shared tier, the ingress model, the
`check` block, the provider and backend blocks — is identical to
[`products/midaz`](../midaz/README.md) and is not re-explained here. What *is*
different is the chart, and the chart is where every interesting difference
lives.

---

## Why these three

From the chart discovery in `infrastructure/IAC/product-infra-dependencies.yaml`:

```yaml
notifications:
  postgresql: yes
  mongodb:    no
  valkey:     yes
  rabbitmq:   yes
  redpanda:   no
```

Reading the chart confirms all three, and adds the detail the YAML could not
carry: **the chart declares no dependencies at all.**

`notifications/Chart.yaml` has no `dependencies:` block. It ends with a comment
saying so:

> `# No dependencies: Postgres, Redis and RabbitMQ are external (provided by the`
> `# target environment / gitops).`

and `values.yaml` repeats it at the top:

> `# External dependencies (NOT bundled): Postgres, Redis, RabbitMQ.`

**Consequence: there is no `postgresql.enabled: false` to set.** midaz and the
two `plugin-br-*` charts bundle Bitnami subcharts that must be switched off when
a managed service exists; this one never had them. Nothing has to be disabled
alongside RDS, ElastiCache or AmazonMQ — just fill in the connection variables.

---

## One ConfigMap, one Secret, four components

The chart is `lerian.studio/chart-type: multi-component` and deploys five
workloads:

| Component | Image | Port | Purpose |
|---|---|---|---|
| `api` | `lerianstudio/notifications` | 8080 | HTTP API, optional ingress |
| `workerEmail` | `notifications-worker-email` | 8081 | health probe only |
| `workerSms` | `notifications-worker-sms` | 8082 | health probe only |
| `workerWebhook` | `notifications-worker-webhook` | 8083 | health probe only |
| `migrations` | reuses the API image | — | `golang-migrate` pre-install/pre-upgrade Job |

**They all read the same two objects.** Every deployment mounts the shared
ConfigMap and the shared Secret with `envFrom`, and the workers add exactly one
env of their own:

```yaml
envFrom:
  - configMapRef: { name: <fullname> }
  - secretRef:    { name: <fullname> }
env:
  - name: WORKER_HEALTH_ADDRESS      # workers only
    value: ":8081"                   # = the component's containerPort
```

So there is **one** `POSTGRES_HOST`, **one** `REDIS_HOST`, **one**
`RABBITMQ_HOST` for the whole release. That is worth stating because it is not
the norm: `plugin-br-pix-indirect-btg` is also multi-component and gives each
component its own ConfigMap with a *different* env shape.

---

## `config` vs `secrets` — and why `helm_secret_values` exists

The chart splits its env contract in two:

- `.Values.config` → rendered into the ConfigMap (`templates/configmap.yaml`)
- `.Values.secrets` → rendered into the Secret (`templates/secrets.yaml`), or
  skipped entirely when `secretRef.name` points at an externally-managed Secret

The split is **not** strictly sensitive vs non-sensitive. Several plain
addresses and flags live on the `secrets` side:

| Key | Where the chart reads it | Sensitive? |
|---|---|---|
| `POSTGRES_REPLICA_HOST` / `_PORT` / `_USER` / `_NAME` / `_SSLMODE` | `secrets` | no |
| `REDIS_TLS` | `secrets` | no |
| `RABBITMQ_DEFAULT_USER` | `secrets` | no |
| `POSTGRES_PASSWORD`, `REDIS_PASSWORD`, `RABBITMQ_DEFAULT_PASS`, `DATABASE_URL`, `RABBITMQ_URL` | `secrets` | **yes** |

Terraform cannot merge a value into the wrong block and expect the chart to find
it, so each root exports **two** maps:

```bash
terraform output -json helm_values         # -> merge into .Values.config
terraform output -json helm_secret_values  # -> merge into .Values.secrets
```

`helm_secret_values` never contains a credential. It contains the non-sensitive
values that the chart happens to read from the Secret. The actual passwords are
never Terraform outputs at all — they are read from `secret_name` by External
Secrets, exactly as everywhere else in this repository.

---

## Helm handoff

Verified against chart **1.0.0-beta.4** (appVersion 0.1.0),
`values.yaml` (`config` / `secrets`), `values-template.yaml`,
`templates/configmap.yaml`, `templates/secrets.yaml`,
`templates/migrations-job.yaml` and the four deployment templates.

### postgres

| Terraform | Chart key | Block |
|---|---|---|
| `endpoint` | `POSTGRES_HOST` | `config` |
| `port` | `POSTGRES_PORT` | `config` |
| `username` | `POSTGRES_USER` | `config` |
| `database_name` | `POSTGRES_NAME` | `config` |
| `replica_endpoint` | `POSTGRES_REPLICA_HOST` | `secrets` |
| `port` | `POSTGRES_REPLICA_PORT` | `secrets` |
| `username` | `POSTGRES_REPLICA_USER` | `secrets` |
| `database_name` | `POSTGRES_REPLICA_NAME` | `secrets` |
| `secret_name` → External Secrets | `POSTGRES_PASSWORD`, `POSTGRES_REPLICA_PASSWORD` | `secrets` |

`POSTGRES_NAME` **is** emitted, unlike midaz's `DB_*_NAME`. midaz runs two
logical databases and RDS creates only the first, so Terraform there cannot know
the second. notifications runs one, RDS creates it, and the chart default is the
same string — so the value is a fact, not a guess.

**The replica keys are emitted only when a replica exists.** This is the opposite
of the midaz root, which coalesces `DB_*_REPLICA_HOST` back to the primary.
The reason is the chart: every `POSTGRES_REPLICA_*` key defaults to an empty
string, and the service reads "empty" as "no replica, use the primary pool".
Filling them with the primary's own address would move the read pool onto the
writer while reporting a replica to the operator. With no replica,
`helm_secret_values` is `{}`.

**`DATABASE_URL` is not emitted, and cannot be.** It is the pre-built,
URL-escaped DSN the migrations Job consumes, and it embeds the password —
building it in Terraform would write a cleartext credential into the state file
and into `terraform output`. The chart's own comment explains why it is
pre-built rather than assembled at runtime (the distroless Job has no shell to
URL-encode with). Assemble it in the secret store from `secret_name` plus the
host, port, user and database published here:

```
postgres://USER:URLENCODED_PW@HOST:PORT/DB?sslmode=require
```

`POSTGRES_SSLMODE` is not emitted either: it is a client policy, the chart
default is already `require`, and every RDS instance accepts TLS. Note that this
default differs from the midaz chart's `disable` — do not copy midaz's here.

### valkey

| Terraform | Chart key | Block |
|---|---|---|
| `endpoint` | `REDIS_HOST` | `config` |
| `port` | `REDIS_PORT` | `config` |
| `redis_db_index` | `REDIS_DB` | `config` |
| `endpoint` | `MULTI_TENANT_REDIS_HOST` | `config` |
| `port` | `MULTI_TENANT_REDIS_PORT` | `config` |
| derived from `transit_encryption_mode` | `MULTI_TENANT_REDIS_TLS` | `config` |
| derived from `transit_encryption_mode` | `REDIS_TLS` | `secrets` |
| `secret_name` → External Secrets | `REDIS_PASSWORD`, `MULTI_TENANT_REDIS_PASSWORD` | `secrets` |

> **`REDIS_HOST` is a BARE HOSTNAME here.** The midaz chart removed `REDIS_PORT`
> in its 3.0 and requires `host:port` inline; this chart keeps `REDIS_PORT` as
> its own key (`values.yaml` config, and the chart README documents
> `config.REDIS_HOST` as "External Redis host"). Emitting `host:6379` into
> `REDIS_HOST` on this chart produces a hostname with a colon in it, which
> resolves to nothing. The midaz behaviour is a midaz-chart convention, not a
> Lerian-wide one.

`REDIS_TLS` reports whether TLS is **required**, not whether it is available:
`transit_encryption_mode = "preferred"` means ElastiCache accepts TLS and
plaintext alike and the chart connects in plaintext, so `preferred` reports
`"false"`.

`REDIS_MASTER_NAME` is not emitted — it is a Sentinel construct, and ElastiCache
replication groups expose no Sentinel. The chart's empty default is correct.

### rabbitmq

| Terraform | Chart key | Block |
|---|---|---|
| `endpoint` | `RABBITMQ_HOST` | `config` |
| `port` (5671) | **`RABBITMQ_PORT_AMQP`** | `config` |
| `console_port` (443) | **`RABBITMQ_PORT_HOST`** | `config` |
| `admin_username` | `RABBITMQ_DEFAULT_USER` | `secrets` |
| `secret_name` → External Secrets | `RABBITMQ_DEFAULT_PASS`, `RABBITMQ_URL`, `RABBITMQ_HEALTH_CHECK_URL` | `secrets` |

> **The two port variables mean the OPPOSITE of what they mean in the midaz
> chart.** This is the single most dangerous thing to copy between the two.
>
> | | notifications chart | midaz chart |
> |---|---|---|
> | `RABBITMQ_PORT_AMQP` | the AMQP(S) port | the management HTTP port |
> | `RABBITMQ_PORT_HOST` | the management HTTP port | the AMQP(S) port |
>
> The evidence is the chart's own defaults: `RABBITMQ_PORT_AMQP: "5672"` and
> `RABBITMQ_PORT_HOST: "15672"`. 5672 is AMQP upstream and 15672 is the
> management API, so on this chart each name means what it says.
> `values-template.yaml` reinforces it by listing `RABBITMQ_PORT_AMQP` as the one
> port an operator normally overrides. midaz's inversion is documented in
> [`products/midaz/rabbitmq/README.md`](../midaz/rabbitmq/README.md) and is a
> midaz-chart convention.
>
> The AmazonMQ values are 5671 (AMQPS — there is no plaintext listener) and 443
> (management over HTTPS), not the 5672/15672 the chart defaults to.

`RABBITMQ_URL` is **not** emitted: it is the full AMQP URL and it embeds the
credentials. Assemble it in the secret store from `secret_name` plus the
`amqp_endpoint` output (`amqps://host:5671`, the same URI without credentials):

```
amqps://USER:URLENCODED_PW@HOST:5671/
```

`RABBITMQ_HEALTH_CHECK_URL` is **not** emitted either, and this one is an open
question rather than a policy:

> **CONFIRMAR no chart:** the chart keeps `RABBITMQ_HEALTH_CHECK_URL` in
> `.Values.secrets`, which implies it is expected to carry credentials for the
> management API, but nothing in the chart documents its path or whether the
> credentials are inline. The host half is unambiguous (`https://<endpoint>`,
> port omitted because 443 is implicit); the rest is not. It stays unemitted
> until the notifications team confirms the shape. Related knobs that are also
> chart decisions: `RABBITMQ_ALLOW_INSECURE_HEALTH_CHECK` and
> `RABBITMQ_REQUIRE_HEALTH_ALLOWED_HOSTS`.

`RABBITMQ_VHOST` is not emitted — AmazonMQ creates the default `/` vhost and the
chart default is already `/`, so there is nothing for Terraform to correct.
`RABBITMQ_EXCHANGE` is application topology, not infrastructure: Terraform
creates no exchanges and the broker is empty on first boot.

---

## Deploy order

```
1. examples/aws/bootstrap                (state bucket + lock table, per env)
2. examples/aws/infra-base/vpc           -> lerian-{env}-vpc
3. examples/aws/infra-base/eks           -> lerian-{env}-eks
4. examples/aws/products/shared-resources/*  (OPTIONAL, only for mode = "shared")
5. products/notifications/{postgres,valkey,rabbitmq}   <- in any order, in parallel
6. helm upgrade --install notifications ...
```

Step 2 is the one hard prerequisite. Step 3 is not: the EKS node security group
is resolved with the plural `data "aws_security_groups"`, which returns an empty
list instead of failing, so these stacks apply before the cluster exists and
pick the security group up on the next apply. Until then ingress comes from the
`Type=private` subnet CIDRs.

The migrations Job is a Helm `pre-install`/`pre-upgrade` hook, so it runs against
RDS before the API and the workers start. It needs `DATABASE_URL` in place
before the first release, or the release fails at the hook.

State keys:

| Stack | State key |
|---|---|
| postgres | `aws/products/notifications/postgres/terraform.tfstate` |
| valkey | `aws/products/notifications/valkey/terraform.tfstate` |
| rabbitmq | `aws/products/notifications/rabbitmq/terraform.tfstate` |

```bash
cd examples/aws/products/notifications/postgres

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/notifications/postgres/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

---

## What gets created

With `mode = "dedicated"` and `environment = "dev"`:

| Stack | AWS resource | Secrets Manager |
|---|---|---|
| postgres | `notifications-dev-postgres` (RDS) | `notifications-dev-postgres/password` |
| valkey | `notifications-dev-valkey` (ElastiCache) | `notifications-dev-valkey/auth-token` |
| rabbitmq | `notifications-dev-rabbitmq-single` (AmazonMQ) | `notifications-dev-rabbitmq/password` |

---

## Dev cost

Approximate `us-east-1` on-demand, `mode = "dedicated"`, minimum sizing:

| Stack | Sizing | ~USD/month |
|---|---|---|
| postgres | `db.t4g.micro`, 20 GB | 15 |
| valkey | `cache.t4g.micro`, 1 node | 12 |
| rabbitmq | `mq.m7g.medium`, SINGLE_INSTANCE | 100 |
| **total** | | **~127** |

*Estimates. Price them against your own AWS Pricing Calculator before committing
to a size.*

The broker is worth more than the database and the cache put together, and there
is no cheaper option: AmazonMQ offers the RabbitMQ engine only the `mq.m5.*` and
`mq.m7g.*` families, and the burstable `mq.t3.micro` that would cost about USD
20/month is **ActiveMQ-only** — AmazonMQ refuses it for RabbitMQ in every
deployment mode. Dev's only lever is the node count (`SINGLE_INSTANCE`). If a
dev environment cannot carry it, set `mode = "shared"` on the rabbitmq root and
consume `products/shared-resources/rabbitmq`.
