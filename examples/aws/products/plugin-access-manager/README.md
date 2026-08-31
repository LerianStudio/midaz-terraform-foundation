# products/plugin-access-manager

AWS datastores for **plugin-access-manager** — Lerian's OAuth2/OIDC access
manager, built on Casdoor.

```
examples/aws/products/plugin-access-manager/
├── postgres/     -> _modules/postgres-rds         plugin-access-manager-{env}-postgres
└── valkey/       -> _modules/valkey-elasticache   plugin-access-manager-{env}-valkey
```

See [`../midaz/README.md`](../midaz/README.md) for everything identical across
products: the `lerian-` / `shared-` prefix split, `module.network`, the absence
of private DNS, and why `endpoint` is always the raw AWS host. This README
covers only what is specific to this product — and it is the most
idiosyncratic chart in the batch.

---

## Why these two

`infrastructure/IAC/product-infra-dependencies.yaml` records:

```yaml
plugin-access-manager:
  postgresql: yes      # subchart com alias auth-database (Casdoor)
  mongodb:    no
  valkey:     yes
  rabbitmq:   no
  redpanda:   no
```

Reading the chart confirms it exactly, alias included. `Chart.yaml:31-40`:

```yaml
dependencies:
  - name: postgresql
    alias: auth-database          # <- the values key is auth-database
    version: "16.3.5"
    condition: auth-database.enabled
  - name: valkey
    version: "2.4.6"
    condition: valkey.enabled
```

No MongoDB, no RabbitMQ, no Kafka, no S3: a grep for
`RABBITMQ|AMQP|KAFKA|MONGO|S3_|BUCKET` across `templates/`, `values.yaml` and
`values-template.yaml` returns **zero** matches.

## Turning the subcharts off

```yaml
auth-database:
  enabled: false     # values.yaml:405 — NOTE the alias, not `postgresql:`
valkey:
  enabled: false     # values.yaml:445
```

> **`auth-database`, not `postgresql`.** The dependency is Bitnami's
> `postgresql` chart under an alias, so `postgresql.enabled: false` sets a key
> nothing reads and the in-cluster database deploys anyway, next to the RDS
> instance nobody talks to.

### The `external` flag is real but undeclared

`templates/_helpers.tpl` and `templates/auth/secrets.yaml:13` both branch on
`auth-database.external`, yet **no such key exists in `values.yaml` or
`values-template.yaml`** — it appears only in a comment at `values.yaml:303`.
It is a template-consumed flag an operator has to add by hand.

It decides where `DB_PASSWORD` comes from
(`templates/_helpers.tpl:168-196`, `plugin-auth.dbPasswordEnv`), in this order:

1. `auth-database.auth.existingSecret` → key `password`
2. otherwise, if the subchart is internal → the subchart's own generated Secret
3. otherwise → `auth.secrets.DB_PASSWORD`, key `DB_PASSWORD`

With RDS, path 1 or 3 is what you want. Point the External Secrets Operator at
`secret_name` from the postgres root and pick whichever of the two matches your
ESO conventions.

## The three components

| Component | Deployment | Database | Cache |
|---|---|---|---|
| `identity` | yes | **none** | `identity.configmap` `REDIS_*` |
| `auth` | yes | `auth.configmap` `DB_*` | `auth.configmap` `REDIS_*` |
| `auth-backend` (Casdoor) | yes | **reads the `auth` ConfigMap by reference** | none |

Plus two Jobs: `templates/auth-backend/migrations.yaml` and
`templates/auth/init_user.yaml`, both reading the same `auth` ConfigMap.

This asymmetry is the thing to get right:

- **Database keys go on `auth.configmap` and nowhere else.** `auth-backend` has
  no database ConfigMap of its own; it pulls `DB_HOST`, `DB_PORT`, `DB_USER`,
  `DB_NAME` and `DB_SSLMODE` with `configMapKeyRef` against the `auth` component
  (`templates/auth-backend/deployment.yaml:74-98`) and assembles Casdoor's
  connection string in a shell command at container start (`:68`):

  ```sh
  export dataSourceName="user=${DB_USER} password=${DB_PASSWORD} host=${DB_HOST} port=${DB_PORT} sslmode=${DB_SSLMODE} dbname=${DB_NAME}"
  ```

- **Cache keys go on BOTH `identity.configmap` AND `auth.configmap`.** They are
  independent maps with identically named keys. Setting one leaves the other
  pointed at the in-cluster default `plugin-access-manager-valkey-primary`.

## Helm handoff

| Root | Chart target | Keys |
|---|---|---|
| postgres | `auth.configmap` **only** | `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER` |
| valkey | `identity.configmap` **and** `auth.configmap` | `REDIS_HOST`, `REDIS_PORT`, `REDIS_TLS` |

Verified against chart **plugin-access-manager 8.6.0** (appVersion 3.1.0),
`templates/auth/configmap.yaml:24-37,75-79`,
`templates/identity/configmap.yaml:54-67`, `values.yaml:284-294`.

### `REDIS_HOST` must be BARE — the chart appends the port itself

This is the single most dangerous line in this product's wiring, and it is the
**exact opposite** of the midaz rule.

Both ConfigMap templates render:

```
printf "%s:%s" <REDIS_HOST value> <REDIS_PORT value>
```

(`templates/auth/configmap.yaml:24`, `templates/identity/configmap.yaml:54`.)

The values key is a **hostname**; the *rendered env var* is `host:port`. So
passing `"my-cache:6379"` into values produces `"my-cache:6379:6379"` in the
ConfigMap.

Three Lerian charts, three behaviours behind one variable name:

| Chart | what the `REDIS_HOST` **values key** takes |
|---|---|
| midaz | `"host:port"` — `REDIS_PORT` was deleted in chart 3.0 |
| br-consignado-gw | `"host:port"` — it is the only Redis key the chart has |
| **plugin-access-manager** | **bare host** — the template appends `REDIS_PORT` |
| tracer | bare host, but the key is `MULTI_TENANT_REDIS_HOST` |

Read the template before copying a `helm_values` block between products.

### `DB_NAME` must be `casdoor`

Not a convention — a hard constraint.
`templates/auth-backend/configmap.yaml:10` hard-codes `dbName: casdoor` as a
literal in Casdoor's Beego config. It is **not templated from any values key**
and cannot be overridden from Helm. `values.yaml:287` and `values.yaml:417`
agree. Changing `database_name` in the tfvars breaks Casdoor, not just the
wiring.

### Not emitted, on purpose

| Key | Why |
|---|---|
| `DB_PASSWORD` | read from `secret_name` by External Secrets. Resolution order above; the two Jobs call the same value **`DB_PASS`**, not `DB_PASSWORD`. |
| `REDIS_PASSWORD` | same. Present on both components. |
| `DB_SSLMODE` | client policy, not an infrastructure fact. Chart default `"disable"` (`values.yaml:288`). Mind the spelling drift: the ConfigMap key is `DB_SSLMODE`, but `templates/auth/init_user.yaml:76` exposes it to its container as `DB_SSL_MODE`. |
| `USER_EXECUTE_COMMAND` | chart default `"postgres"` (`templates/auth/configmap.yaml:80`). It happens to match this stack's master username, but it is an application setting. |
| **`REDIS_USER`** | **`# CONFIRMAR no chart`** — see below. |
| `REDIS_CA_CERT` | the ElastiCache CA bundle; nothing in this repository distributes it. |
| `REDIS_MASTER_NAME` | a Redis **Sentinel** master name. ElastiCache replication groups are not Sentinel; the primary endpoint is already the failover-aware address. |
| `REDIS_DB`, `REDIS_PROTOCOL`, `REDIS_SCAN_COUNT`, `REDIS_TOKEN_LIFETIME`, `REDIS_TOKEN_REFRESH_DURATION` | application tuning. |
| `REDIS_USE_GCP_IAM`, `REDIS_SERVICE_ACCOUNT`, `GOOGLE_APPLICATION_CREDENTIALS` | a Google Memorystore IAM path. Not applicable on AWS. |

## `REDIS_USER` blocks auth-token enforcement

`auth_token_enabled` stays `false` in every environment, and here the reason is
**not** the usual "the chart has no password field" — it has one.

The blocker is `REDIS_USER`. The chart sends a Redis **username** (default
`"auth"` on the auth component, `values.yaml:294`; `"identity"` on identity).
ElastiCache auth tokens are the **legacy password-only AUTH**, which has no
username at all: a client that sends `AUTH <user> <token>` against a
token-protected replication group is rejected.

Making this work needs **ElastiCache RBAC users**, which
`_modules/valkey-elasticache` does not create. Until then the cache is protected
by the security group and the private subnets alone, and the token is generated
and stored at `plugin-access-manager-{env}-valkey/auth-token` regardless.

`REDIS_USER` is therefore left to the operator rather than guessed — Terraform
cannot emit a correct value in either state.

`transit_encryption_mode` stays `"preferred"` for the familiar reason: the chart
does have a `REDIS_TLS` key for this stack's value to land in, but it also has
`REDIS_CA_CERT`, and nothing distributes the ElastiCache CA bundle into the
pods.

## Blast radius

This is the one product in this batch whose PostgreSQL instance is not
recoverable by re-running a migration. It holds the Casdoor identity data —
users, organisations, applications, Casbin policies — for **every** Lerian
product that authenticates through it, including `br-consignado-gw`, which
consumes this Casdoor as an external IdP.

`deletion_protection = true` and `skip_final_snapshot = false` in prd are not
boilerplate here.

## Deploy order

```
1. examples/aws/bootstrap
2. examples/aws/infra-base/vpc            -> lerian-{env}-vpc
3. examples/aws/infra-base/eks            -> lerian-{env}-eks
4. examples/aws/products/shared-resources/*   (OPTIONAL, only for mode = "shared")
5. products/plugin-access-manager/{postgres,valkey}   <- in any order, in parallel
6. helm upgrade --install plugin-access-manager ...
7. the products that consume this Casdoor (br-consignado-gw, ...)
```

The two roots in step 5 have no dependency on each other.

## Running a stack

```bash
cd examples/aws/products/plugin-access-manager/postgres

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/plugin-access-manager/postgres/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

| Stack | State key |
|---|---|
| postgres | `aws/products/plugin-access-manager/postgres/terraform.tfstate` |
| valkey | `aws/products/plugin-access-manager/valkey/terraform.tfstate` |

## What gets created

`mode = "dedicated"`, `environment = "dev"`:

| Stack | AWS resource | Secrets Manager | ~USD/month |
|---|---|---|---|
| postgres | `plugin-access-manager-dev-postgres` (RDS `db.t4g.micro`, 20 GB) | `plugin-access-manager-dev-postgres/password` | 15 |
| valkey | `plugin-access-manager-dev-valkey` (ElastiCache `cache.t4g.micro`, 1 node) | `plugin-access-manager-dev-valkey/auth-token` | 12 |
| **total** | | | **~27** |

The derived names are the longest in this batch.
`plugin-access-manager-prd-valkey` is 32 characters against the ElastiCache
`replication_group_id` limit of **40** — the module asserts it at plan time
(`_modules/valkey-elasticache/main.tf:180`), so a future rename that overruns
fails the plan rather than the apply. Estimates; price them yourself.
