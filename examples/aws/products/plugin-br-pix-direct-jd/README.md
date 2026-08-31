# products/plugin-br-pix-direct-jd

AWS datastores for **plugin-br-pix-direct-jd** — Pix Direto over the JD partner
interface.

One root stack, one datastore:

```
examples/aws/products/plugin-br-pix-direct-jd/
└── postgres/     -> _modules/postgres-rds     plugin-br-pix-direct-jd-{env}-postgres
```

The directory name is the **chart** name, verbatim. There is a sibling chart
called `plugin-br-pix-jd` (no `-direct-`) and another called
`plugin-br-pix-indirect-btg`; keeping the full chart name is what stops the three
from being confused for one another.

---

## Why only one

From the chart discovery in
`infrastructure/IAC/product-infra-dependencies.yaml`:

```yaml
plugin-br-pix-direct-jd:
  postgresql: yes
  mongodb:    no
  valkey:     no
  rabbitmq:   no
  redpanda:   no
```

Confirmed by reading `plugin-br-pix-direct-jd-helm` 3.0.0 directly. Grep over the
whole chart: `redis` **0**, `valkey` **0**, `rabbitmq` **0**, `amqp` **0**,
`kafka` **0**, `streaming` **0**, `broker` **0**, `redpanda` **0**, `mongo`
**1** — and that single hit is a stale comment heading `# MONGO Secrets` in
`templates/plugin-br-pix-direct-jd-qr-code/secrets.yaml:11`, above keys that are
actually the mTLS cert-provider materials (`KEY`, `CERTIFICATE`, `NEW_KEY`).

> Two documentation defects found while confirming this, neither of which changes
> the infrastructure: the stale `# MONGO Secrets` heading above, and
> `README.md:8` of the chart telling operators to supply "messaging credentials"
> when no messaging variable exists in the chart at all. Both look like
> boilerplate carried over from a sibling.

### Chart shape

Three components, one database between them:

| Component | Kind | Reads the database |
|---|---|---|
| `pix` | Deployment, port 4011 | yes |
| `job` | CronJob | yes |
| `qrcode` | Deployment (`lerianstudio/cert-provider`), port 4009 | no — its ConfigMap has four keys and none is a datastore |

| Chart dependency | Version | Repository | Turn off with |
|---|---|---|---|
| `postgresql` | 16.3.5 | charts.bitnami.com/bitnami | `postgresql.enabled: false` + `postgresql.external: true` |

Default is `postgresql.enabled: true` (`values.yaml:389`).

---

## Dedicated or shared

| `mode` | What the stack does | Resources created |
|---|---|---|
| `dedicated` (default) | Creates the instance under the plugin-br-pix-direct-jd name, with its own security group and secret. | All of them |
| `shared` | Creates nothing. Resolves `shared-{env}-postgres` **by name** through `data "aws_db_instance"`, plus `shared-{env}-postgres/password` from Secrets Manager. | None |

```
dedicated   plugin-br-pix-direct-jd-dev-postgres    plugin-br-pix-direct-jd-dev-postgres/password
shared      shared-dev-postgres                     shared-dev-postgres/password
```

`security_group_id` comes back `null` in shared mode: opening the shared instance
is `products/shared-resources/postgres`' job.

---

## Deploy order

```
1. examples/aws/bootstrap                (state bucket + lock table, per env)
2. examples/aws/infra-base/vpc           -> lerian-{env}-vpc
3. examples/aws/infra-base/eks           -> lerian-{env}-eks
4. examples/aws/products/shared-resources/postgres   (OPTIONAL, only for mode = "shared")
5. products/plugin-br-pix-direct-jd/postgres
6. helm upgrade --install plugin-br-pix-direct-jd ...
```

Step 2 is the one hard prerequisite. **Step 3 is not**: the EKS node security
group is resolved with the *plural* `data "aws_security_groups"`, which returns
an empty list instead of failing, so the stack applies before the cluster exists
and picks the group up on the next apply.

```bash
cd examples/aws/products/plugin-br-pix-direct-jd/postgres

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/plugin-br-pix-direct-jd/postgres/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

`../../../` is **three** levels up and lands on `examples/aws`, where both
`backend/` and `_modules/` live. Verified with `terraform init`.

`*.tfvars` is gitignored; `*.tfvars-example` is not. Copy, then edit.

---

## What gets created

With `mode = "dedicated"` and `environment = "dev"`:

| Stack | AWS resource | Secrets Manager |
|---|---|---|
| postgres | `plugin-br-pix-direct-jd-dev-postgres` (RDS) | `plugin-br-pix-direct-jd-dev-postgres/password` |

---

## Helm handoff

```bash
cd examples/aws/products/plugin-br-pix-direct-jd/postgres
terraform output -json helm_values | jq
```

Verified against chart **plugin-br-pix-direct-jd-helm 3.0.0** (appVersion
`1.2.1-beta.11`), `templates/plugin-br-pix-direct-jd/configmap.yaml:45-52` and
`:90-93`.

| Terraform | Chart env var |
|---|---|
| `endpoint` | `DATABASE_HOST` |
| `port` | `DATABASE_PORT`, `POSTGRES_PORT` |
| `username` | `DATABASE_USER`, `POSTGRES_USER` |
| `database_name` | `DATABASE_NAME`, `POSTGRES_DB` |
| `secret_name` → External Secrets | `pix.secrets.DATABASE_PASSWORD` **and** `pix.secrets.POSTGRES_PASSWORD` |

### Merge it into `pix.configmap` — including for the CronJob

**`job.configmap.DATABASE_*` is dead.** The CronJob's own ConfigMap
(`templates/plugin-br-pix-direct-jd-job/configmap.yaml:44-51`) reads
`.Values.pix.configmap.DATABASE_*`, not `.Values.job.configmap.*`. The
`job.configmap` keys exist in `values.yaml` and setting them changes nothing.

Merge `helm_values` into `pix.configmap` **once** and both workloads are wired.
Setting the job's copy instead is a silent no-op that leaves the CronJob pointed
at the chart's hardcoded default.

### The hardcoded default is a landmine

The chart's shipped `DATABASE_HOST` default is

```
plugin-br-pix-direct-jd-postgresql.midaz-plugins.svc.cluster.local
```

which only resolves for one release name in one namespace — the chart's own
`README.md:23` says so. Overriding it is not optional in any real deployment, and
a typo produces a DNS failure rather than a config error.

### A third spelling: `DATABASE_*`

There is **no Lerian-wide PostgreSQL variable convention.** Across the charts
read for this batch:

| Chart | Host variable |
|---|---|
| midaz | `DB_ONBOARDING_HOST` / `DB_TRANSACTION_HOST` |
| plugin-br-payments | `POSTGRES_HOST` |
| plugin-br-pix-direct-jd | `DATABASE_HOST` |

This chart also renders three `POSTGRES_*` keys that it labels itself as "for
docker-compose compatibility" (`configmap.yaml:90`): `POSTGRES_USER`,
`POSTGRES_DB`, `POSTGRES_PORT`. `helm_values` emits them **consistent with** the
`DATABASE_*` values so the two families cannot disagree.

**There is no `POSTGRES_HOST` key.** `DATABASE_HOST` is the only host variable;
emitting `POSTGRES_HOST` would land an unread key in the ConfigMap.

### `DATABASE_USER` and `DATABASE_NAME` — what Terraform owns

Both are emitted, and here Terraform genuinely owns them: this chart ships **no
bootstrap Job**. With the bundled Bitnami subchart the role and database came
from the container entrypoint reading `POSTGRES_USER` / `POSTGRES_DB`; against an
external RDS instance nothing would create them. `database_name = "pix"` (the
chart default) plus the RDS master is what makes the external path work at all.

`username` stays `postgres`, the RDS master. The chart's `DATABASE_USER` default
is `pix`; if a DBA creates that least-privilege role, override `DATABASE_USER` in
the release rather than changing `username` here — that variable renames the RDS
master and forces a replacement.

### No read replica — and no toggle for one

`products/midaz/postgres` and `products/plugin-br-payments/postgres` both expose
`create_read_replica`. **This root does not**, deliberately.

`grep -rniE "replica"` over the chart returns forty hits and not one is a
database variable: they are all Kubernetes pod replica counts, HPA bounds, and a
single Bitnami `max_replication_slots` line. There is no `DATABASE_REPLICA_HOST`,
no `POSTGRES_REPLICA_*`, nothing. The bundled subchart is not even in replication
mode here (no `architecture` key, so Bitnami defaults to standalone).

Exposing a toggle that can only produce an RDS instance no consumer can reach
would be worse than not exposing it. Add the chart variables first, then the
toggle.

### There is no SSL mode variable at all

`grep -rniE "sslmode"` over the chart returns **nothing** — no `DATABASE_SSLMODE`,
no `POSTGRES_SSLMODE`. Whether the driver negotiates TLS against RDS is decided
inside the application, and this chart offers no way to influence it.

That is worth raising with the service owner: `plugin-br-payments` ships
`POSTGRES_SSLMODE: "require"` for the same class of workload, and this is a Pix
rail. Terraform cannot paper over it — `ALLOW_INSECURE_TLS` (`values.yaml:121`,
default `"true"`) is an outbound HTTP client flag, not a database setting, and
must not be mistaken for one.

`endpoint` is the **raw RDS hostname** in both modes. There is no `dns_name` and
no private zone: the RDS certificate covers `*.{region}.rds.amazonaws.com`, so an
alias in front of it breaks TLS hostname verification for any client that
validates.

### Turning the subchart off

```yaml
postgresql:
  enabled:  false
  external: true
```

> Structural quirk in the chart, not something Terraform emits: `values.yaml`
> nests `persistence`, `resourcesPreset`, `extendedConfiguration` and
> `extraEnvVars` under **`postgresql.auth`** instead of `postgresql.primary`
> (`values.yaml:391-417`). Bitnami ignores all of them. It stops mattering once
> the subchart is off; do not replicate the nesting.

---

## Secrets

No stack outputs a password. `secret_name` and `secret_arn` are outputs; the
value is read from Secrets Manager by External Secrets Operator.

| Stack | Secret (dedicated) | Secret (shared) |
|---|---|---|
| postgres | `plugin-br-pix-direct-jd-{env}-postgres/password` | `shared-{env}-postgres/password` |

**One secret feeds two chart keys.** `templates/plugin-br-pix-direct-jd/deployment.yaml:47-48`
wires `DATABASE_PASSWORD` and `POSTGRES_PASSWORD` from the same source; the
CronJob (`cronjob.yaml:42`) reads `DATABASE_PASSWORD` only. Populate both keys
from this one secret.

---

## Dev cost

Approximate `us-east-1` on-demand, `mode = "dedicated"`, minimum sizing:

| Stack | Sizing | ~USD/month |
|---|---|---|
| postgres | `db.t4g.micro`, 20 GB | 15 |
| **total** | | **~15** |

*These are estimates. Price them against your own AWS Pricing Calculator before
committing to a size.*

Two sizing traps the module catches at **plan** time:

- **Performance Insights on `db.t4g.micro`.** AWS does not offer it on t2/t3/t4g
  micro and small; `performance_insights_enabled` must be `false` in dev.
- **`monitoring_interval > 0` with `create_monitoring_role = false`** fails the
  apply on the missing IAM role.

And one that only shows up in a real account: **`engine_version` stays MAJOR-only
(`"16"`)**. AWS retired 16.3 and every apply that pinned it started failing with
`Cannot find version 16.3 for postgres`.

`prd.tfvars-example` sets `multi_az = true`: BACEN settlement messages arrive
whether or not the database is up, and a single-AZ instance turns an AZ event
into a reconciliation exercise.
