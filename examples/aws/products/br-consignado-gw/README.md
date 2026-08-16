# products/br-consignado-gw

AWS datastores for **br-consignado-gw** — the consignado (payroll-deducted
lending) gateway on the Dataprev rail.

```
examples/aws/products/br-consignado-gw/
├── postgres/     -> _modules/postgres-rds         br-consignado-gw-{env}-postgres
└── valkey/       -> _modules/valkey-elasticache   br-consignado-gw-{env}-valkey
```

See [`../midaz/README.md`](../midaz/README.md) for everything identical across
products: the `lerian-` / `shared-` prefix split, `module.network`, the absence
of private DNS, and why `endpoint` is always the raw AWS host.

---

## Why these two, and why there is no `rabbitmq/`

`infrastructure/IAC/product-infra-dependencies.yaml` records:

```yaml
br-consignado-gw:
  postgresql: yes
  mongodb:    no
  valkey:     yes
  rabbitmq:   no    # mencao em comentario de template, mas nenhuma env var AMQP existe
  redpanda:   no    # extras: consome Casdoor (plugin-access-manager) externo
```

**The RabbitMQ line was checked and is correct.** A case-insensitive grep for
`rabbitmq|amqp|rabbit` across the whole chart returns exactly **two** hits, and
neither is configuration:

| # | Location | What it is |
|---|---|---|
| 1 | `values-template.yaml:2` | a comment: *"This chart does not deploy Postgres, Valkey, RabbitMQ, or Casdoor — target tiers provide those services."* |
| 2 | `README.md:13` | prose: *"Postgres, Valkey/Redis, RabbitMQ/Redpanda, Casdoor, and image credentials are external platform services. The chart deliberately has no infra subcharts."* |

There is **no** `RABBITMQ_*` or `AMQP_*` env var in `values.yaml`,
`values-template.yaml`, `values.schema.json` or any file under `templates/`; no
RabbitMQ subchart; and no Go-template expression referencing AMQP anywhere.

So the mention is aspirational, not wired. **There is no `rabbitmq/` root here
because there is nothing to point one at**: provisioning an AmazonMQ broker
would cost roughly **USD 100/month** — `mq.m7g.medium` is the smallest RabbitMQ
type AmazonMQ offers, and the cheap `mq.t3.micro` is ActiveMQ-only — for a
broker whose address the chart has no variable to receive.

If the chart later grows AMQP variables, add `products/br-consignado-gw/rabbitmq/`
following the shape of `products/midaz/rabbitmq`, and mind the two traps
documented there: `RABBITMQ_PORT_HOST` is the AMQPS port while
`RABBITMQ_PORT_AMQP` is the management port, and shared mode needs
`shared_broker_name` spelled out with its `-single` / `-cluster` suffix.

Same for Kafka/MSK, Mongo and S3: grepping
`kafka|broker|streaming|mongo|s3|bucket|msk` returns **zero** matches.

## No subcharts at all

`Chart.yaml` has **no `dependencies:` block**, which the chart states as a
deliberate choice (`README.md:13`: *"The chart deliberately has no infra
subcharts"*).

Consequences:

- there is **no `postgresql.enabled: false`** and **no `valkey.enabled: false`**
  to set — nothing bundled to turn off;
- the "toggles" in `values.yaml` are component switches, not infra ones:
  `api.enabled` (`:17`), `ui.enabled` (`:73`), `migrations.enabled` (`:147`),
  all **`false` by default** so operators choose explicitly what to install;
- the chart ships **empty strings** as defaults for every connection value, so
  a release with `helm_values` unwired fails to connect rather than quietly
  aiming at an in-cluster service. That is friendlier than the tracer chart's
  behaviour, but it still means the wiring is mandatory.

## Casdoor is external, and belongs to another product

The chart consumes Casdoor as a fully external IdP — the one run by
[`../plugin-access-manager`](../plugin-access-manager). It exposes six
**UI-only** client values, rendered into `/config.js` through `ui.configmap`
(`templates/ui-configmap.yaml:10-11`), so they are browser-visible by design:

| Key | Default | `values.yaml` |
|---|---|---|
| `CASDOOR_CSP_ORIGIN` | `""` | 111 |
| `CASDOOR_ENDPOINT` | `""` | 112 |
| `CASDOOR_CLIENT_ID` | `""` | 113 |
| `CASDOOR_ORG_NAME` | `""` | 114 |
| `CASDOOR_APP_NAME` | `""` | 115 |
| `AUTH_DISABLED` | `"false"` | 116 |

None of them is emitted by Terraform: they describe an application registration
inside Casdoor, not an AWS resource. Deploy `plugin-access-manager` first and
take them from there.

## Helm handoff

| Root | Chart target | Keys |
|---|---|---|
| postgres | `api.configmap` | `POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_USER`, `POSTGRES_NAME` |
| valkey | `api.configmap` | `REDIS_HOST` (one key, carrying `host:port`) |

Verified against chart **br-consignado-gw-helm 1.0.0** (appVersion
1.3.0-beta.36), `values.yaml:56-61`, `templates/api-configmap.yaml:10-11`,
`docs/UPGRADE-1.0.md:138`.

```bash
cd examples/aws/products/br-consignado-gw/postgres
terraform output -json helm_values | jq
```

### The family is `POSTGRES_*`, and the DB key is `POSTGRES_NAME`

Not `DB_*`, and not `POSTGRES_DB` or `POSTGRES_DATABASE`. Three readable Lerian
charts, three families:

| Chart | PostgreSQL variable family |
|---|---|
| midaz | `DB_ONBOARDING_*` / `DB_TRANSACTION_*`, no plain `DB_HOST` |
| tracer, plugin-access-manager | `DB_HOST` / `DB_PORT` / `DB_NAME` / `DB_USER` |
| **br-consignado-gw** | **`POSTGRES_HOST` / `POSTGRES_PORT` / `POSTGRES_USER` / `POSTGRES_NAME`** |

`templates/api-configmap.yaml` dumps `api.configmap` **verbatim** into the
ConfigMap — no allowlist, no renaming. A typo therefore becomes a silently
ignored env var, not a render error.

### `REDIS_HOST` carries `host:port`

The chart defines **no `REDIS_PORT`**. Grepping `REDIS` across the whole chart
returns `values.yaml:61`, `values-template.yaml:17` and documentation examples —
one key, nothing else. The port goes inside it, as the chart's own upgrade guide
shows verbatim (`docs/UPGRADE-1.0.md:138`):

```yaml
REDIS_HOST: "redis.cache.svc.cluster.local:6379"
```

Same shape as midaz, and the **opposite** of `plugin-access-manager`, whose
template appends the port itself so a `host:port` value renders as
`host:port:port`. Emitting a bare hostname here produces a client dialling port
zero.

### The migrations Job inherits the API's values

`templates/migrations-job.yaml:4-8` resolves its own host / port / user /
database / sslMode from `migrations.postgres.*` and **falls back to
`api.configmap`**. Setting `api.configmap` alone is therefore enough for both.
Override `migrations.postgres.*` only to point the migration at a different
instance or a more privileged role.

One difference worth knowing: the Job defaults `sslMode` to `"disable"` when
both sources are empty (`:8`), while `values.yaml:60` leaves the API's
`POSTGRES_SSLMODE` as an empty string.

### Not emitted, on purpose

| Key | Why |
|---|---|
| `POSTGRES_PASSWORD` | read from `secret_name` by External Secrets. It is `api.secrets.POSTGRES_PASSWORD` (`values.yaml:64`); the Job takes the same value inline at `migrations.postgres.password` or by reference at `migrations.postgres.passwordSecret` (`values.yaml:159-162`). |
| `POSTGRES_SSLMODE` | client policy, not an infrastructure fact. Same call the midaz root makes about its `DB_*_SSLMODE`. |
| the `CASDOOR_*` block and `AUTH_DISABLED` | an application registration in an external IdP. |

## Security posture

`auth_token_enabled = false` and `transit_encryption_mode = "preferred"` in all
three environments — and here the reason is **harder than anywhere else in this
batch**: `REDIS_HOST` is the only Redis key the chart defines. There is no
`REDIS_PASSWORD` and no `REDIS_TLS`.

So an enforced auth token has no way to reach the client, and a TLS-required
listener has no way to be negotiated. **Closing this gap needs a chart change
first**, not a tfvars change — unlike tracer, where both knobs already exist.

The token is generated and stored at
`br-consignado-gw-{env}-valkey/auth-token` regardless, so the day the chart
grows the variables, enabling it is one tfvars line. Until then the cache is
protected by the security group and the private subnets alone.

## Deploy order

```
1. examples/aws/bootstrap
2. examples/aws/infra-base/vpc            -> lerian-{env}-vpc
3. examples/aws/infra-base/eks            -> lerian-{env}-eks
4. examples/aws/products/shared-resources/*   (OPTIONAL, only for mode = "shared")
5. products/plugin-access-manager/*        (the Casdoor this product authenticates against)
6. products/br-consignado-gw/{postgres,valkey}   <- in any order, in parallel
7. helm upgrade --install br-consignado-gw ...
```

Step 5 is not a Terraform dependency — no state or data source crosses between
them — but the release cannot authenticate until that Casdoor exists and the
application is registered in it.

## Running a stack

```bash
cd examples/aws/products/br-consignado-gw/postgres

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/br-consignado-gw/postgres/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

| Stack | State key |
|---|---|
| postgres | `aws/products/br-consignado-gw/postgres/terraform.tfstate` |
| valkey | `aws/products/br-consignado-gw/valkey/terraform.tfstate` |

## What gets created

`mode = "dedicated"`, `environment = "dev"`:

| Stack | AWS resource | Secrets Manager | ~USD/month |
|---|---|---|---|
| postgres | `br-consignado-gw-dev-postgres` (RDS `db.t4g.micro`, 20 GB) | `br-consignado-gw-dev-postgres/password` | 15 |
| valkey | `br-consignado-gw-dev-valkey` (ElastiCache `cache.t4g.micro`, 1 node) | `br-consignado-gw-dev-valkey/auth-token` | 12 |
| **total** | | | **~27** |

Estimates; price them against your own AWS Pricing Calculator.
