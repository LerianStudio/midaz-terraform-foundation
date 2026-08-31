# products/br-consignado-gw/postgres

PostgreSQL for the consignado gateway. Root stack over
[`_modules/postgres-rds`](../../../_modules/postgres-rds).

One root, one datastore, one state file. See [`../README.md`](../README.md) for
the product-level picture: why there is no `rabbitmq/` root, the external Casdoor
dependency, and the full Helm mapping.

| | |
|---|---|
| Module | `../../../_modules/postgres-rds` |
| State key | `aws/products/br-consignado-gw/postgres/terraform.tfstate` |
| Creates | `br-consignado-gw-{env}-postgres` (RDS instance) |
| Secret | `br-consignado-gw-{env}-postgres/password` |
| Chart target | `api.configmap` (`POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_USER`, `POSTGRES_NAME`) |

## Run it

```bash
cd examples/aws/products/br-consignado-gw/postgres

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/br-consignado-gw/postgres/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

`../../../` is **three** levels up and lands on `examples/aws`. Verified with
`terraform init -backend=false`.

Prerequisites: `infra-base/vpc`. `infra-base/eks` is optional at apply time.

## Ingress

Resolved by [`_modules/product-network`](../../../_modules/product-network) as
`module.network`, `enabled = var.mode == "dedicated"`: `Type=private` subnet
CIDRs (works from the first apply, needs only `infra-base/vpc`) plus the EKS
node security group matched by `tag:Name = "lerian-{env}-eks-node"` with the
**plural** data source, so an absent cluster returns an empty list instead of
failing the plan.

> `var.subnet_tag_type` (`"database"`) is the **placement** filter and goes to
> `postgres-rds` only. `product-network` keeps its own default (`"private"`),
> the **ingress** filter.

`allow_vpc_cidr_ingress` is `false`: a fallback the module applies only when
*both* allow lists resolve empty. The "nothing can reach this instance" case is
not re-asserted here — the module carries `check "ingress_is_reachable"`.

## The variable family is `POSTGRES_*`, not `DB_*`

And the database key is **`POSTGRES_NAME`** — not `POSTGRES_DB`, not
`POSTGRES_DATABASE`.

Four readable Lerian charts, three families:

| Chart | family |
|---|---|
| midaz | `DB_ONBOARDING_*` / `DB_TRANSACTION_*`, no plain `DB_HOST` |
| tracer, plugin-access-manager | `DB_HOST` / `DB_PORT` / `DB_NAME` / `DB_USER` |
| **br-consignado-gw** | **`POSTGRES_HOST` / `POSTGRES_PORT` / `POSTGRES_USER` / `POSTGRES_NAME`** |

`templates/api-configmap.yaml:10-11` dumps `api.configmap` **verbatim** into the
ConfigMap — no allowlist, no renaming — which the api Deployment consumes with
`envFrom` (`templates/api-deployment.yaml:40-42`). A typo therefore becomes a
silently ignored env var, not a render error.

## No subcharts — nothing to turn off

`Chart.yaml` has **no `dependencies:` block**, stated as deliberate at
`README.md:13`: *"The chart deliberately has no infra subcharts."* So there is
no `postgresql.enabled: false` to set.

The chart ships empty strings as defaults for every connection value
(`values.yaml:56-60`), so an unwired release fails to connect rather than
quietly aiming at an in-cluster service — friendlier than the tracer chart's
behaviour, but the wiring is still mandatory.

Do not forget the component switches, all `false` by default:
`api.enabled` (`values.yaml:17`), `ui.enabled` (`:73`),
`migrations.enabled` (`:147`).

## `database_name` is authoritative here

The chart ships **no default** for `POSTGRES_NAME` (`values.yaml:59` is an empty
string), so this stack's `database_name` is the source of truth rather than a
mirror of a chart default. Same for `POSTGRES_USER` (`values.yaml:58`).

br-consignado-gw runs a single logical database, so `helm_values` can emit the
name — the midaz root cannot, because midaz runs two and RDS creates one.

`username` defaults to `"postgres"`, the RDS **master** user: the only role that
exists on a fresh instance. Nothing in the chart contradicts it.

## The migrations Job inherits these values

`templates/migrations-job.yaml:4-8` resolves its own host / port / user /
database / sslMode from `migrations.postgres.*` and **falls back to
`api.configmap`**. Setting `api.configmap` alone is enough for both. Override
`migrations.postgres.*` only to point the migration at a different instance or a
more privileged role.

One difference worth knowing: the Job defaults `sslMode` to `"disable"` when
both sources are empty (`:8`), while `values.yaml:60` leaves the API's
`POSTGRES_SSLMODE` as an empty string.

The Job takes the password inline at `migrations.postgres.password` or by
reference at `migrations.postgres.passwordSecret`
(`values.yaml:159-162`, key `POSTGRES_PASSWORD`).

## Sizing traps

| Trap | Consequence | Caught |
|---|---|---|
| `performance_insights_enabled = true` on `db.t4g.micro` | AWS does not offer PI on t2/t3/t4g micro and small | Module precondition, at **plan** time |
| `engine_version = "16.3"` | AWS retired that minor; `Cannot find version 16.3 for postgres` | Only at apply, in a real account — hence MAJOR-only `"16"` |
| `monitoring_interval > 0` with `create_monitoring_role = false` | Apply fails on the missing IAM role | Apply |

## Read replica

Off in every environment. The chart defines one `POSTGRES_HOST` and no reader
variable, so a replica would have nothing able to address it.
`replica_endpoint` is published for the day one appears.

## Outputs

Seven uniform contract names — `mode`, `endpoint`, `port`, `security_group_id`,
`secret_arn`, `secret_name`, `identifier` — plus `database_name`, `username`,
`replica_*`, `subnet_group_name`, the cross-stack context, and `helm_values`.

`endpoint` is the raw RDS hostname in both modes. There is no `dns_name`: the
RDS certificate covers `*.{region}.rds.amazonaws.com`.

```bash
terraform output -json helm_values | jq
```

No password is ever an output. `secret_name` is what an External Secrets
Operator `ExternalSecret` references to populate
`api.secrets.POSTGRES_PASSWORD` (`values.yaml:64`).

`POSTGRES_SSLMODE` is **not** emitted — a client policy decision, not an
infrastructure fact.

## Shared mode

`mode = "shared"` creates nothing and plans to zero resources. Every lookup is
gated on `mode == "dedicated"`, so the VPC does not even need to exist. The
module resolves `shared-{env}-postgres` with `data "aws_db_instance"` and the
secret `shared-{env}-postgres/password` with
`data "aws_secretsmanager_secret"`; `endpoint`, `port`, `username` and
`database_name` come from the resolved instance. `security_group_id` comes back
`null`.

The name is fully derived, so this root exposes no variable for it. The module's
own `shared_identifier` is the escape hatch.

Every sizing variable in the tfvars is ignored in that mode.
