# products/br-sisbajud/postgres

PostgreSQL for the br-sisbajud SISBAJUD plugin — the judicial asset
blocking/unblocking integration with BACEN SISBAJUD. Root stack over
[`_modules/postgres-rds`](../../../_modules/postgres-rds).

One root, one datastore, one state file. See [`../README.md`](../README.md) for
the product-level picture: deploy order, the shared-vs-dedicated model, and the
full Helm mapping.

| | |
|---|---|
| Module | `../../../_modules/postgres-rds` |
| State key | `aws/products/br-sisbajud/postgres/terraform.tfstate` |
| Creates | `br-sisbajud-{env}-postgres` (RDS instance) |
| Secret | `br-sisbajud-{env}-postgres/password` |
| Chart target | `brSisbajud.configmap` (`POSTGRES_*`) |
| Chart verified | br-sisbajud 1.1.0, appVersion `1.0.0-beta.109` |

## Run it

```bash
cd examples/aws/products/br-sisbajud/postgres

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/br-sisbajud/postgres/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

`../../../` is **three** levels up and lands on `examples/aws`, where both
`backend/` and `_modules/` live. Verified with `terraform init`.

Prerequisites: `infra-base/vpc`. `infra-base/eks` is optional at apply time —
see *Ingress* below.

## What this root decides

The module already resolves the VPC and the subnets by itself. This root exists
for three things the module cannot do:

1. **Derive the cross-stack names.** `lerian-{env}-vpc` and `lerian-{env}-eks`.
   Note the `lerian` prefix on both: they belong to `infra-base`, not to br-sisbajud.
   That is also why this root does **not** call the `naming` module — seeding it
   with `product = "br-sisbajud"` would derive `br-sisbajud-{env}-vpc`, which does not
   exist.
2. **Compute the ingress allow list.** Which sources may reach the database is a
   decision about the EKS cluster, not about the database.
3. **Translate to the chart.** The `helm_values` output.

It creates no AWS resource of its own.

## Ingress

Steps 1 and 2 above are performed by
[`_modules/product-network`](../../../_modules/product-network), called here as
`module.network` with `enabled = var.mode == "dedicated"`. The name derivation,
the private subnet CIDR lookup, the EKS node security group lookup and
`check "eks_node_security_group_resolved"` all live in that module — written
once for every product root instead of copied into each service directory. This
stack hands `module.network.ingress_security_group_ids` and
`module.network.ingress_cidr_blocks` straight to `postgres-rds`.

Two sources, merged and handed to the module:

- **`Type=private` subnet CIDRs** (`allow_private_subnet_cidr_ingress`, default
  true). Depends only on `infra-base/vpc`, so it works from the very first apply.
  Strictly tighter than the module's VPC-CIDR fallback, which would also cover
  the public subnets.
- **the EKS node security group**, matched by
  `tag:Name = "lerian-{env}-eks-node"`, resolved with the **plural**
  `data "aws_security_groups"` so an absent cluster returns an empty list rather
  than failing the plan. `check "eks_node_security_group_resolved"` warns while
  the lookup is empty; a warning that survives into steady state is the signal.
  The product-network README explains why the plural form is mandatory.

> `var.subnet_tag_type` (`"database"`) selects the subnets the **instance is
> placed in** and goes to `postgres-rds` only. `product-network` keeps its own
> default (`"private"`), the subnets whose CIDRs become **ingress**. Do not
> forward one into the other.

`allow_vpc_cidr_ingress` is `false` here. It is a fallback the module applies only
when *both* allow lists resolve empty — any explicit entry wins outright and the
VPC CIDR is never added on top.

The "nothing can reach this instance at all" case is **not** re-asserted here:
the module already carries `check "ingress_is_reachable"` for it.

## Sizing traps

| Trap | Consequence | Where it is caught |
|---|---|---|
| `performance_insights_enabled = true` on `db.t4g.micro` | AWS does not offer PI on t2/t3/t4g micro and small | Module precondition, at **plan** time |
| `engine_version = "16.3"` | AWS retired that minor; `Cannot find version 16.3 for postgres` | Only at apply, in a real account — which is why the default is MAJOR-only `"16"` |
| `monitoring_interval > 0` with `create_monitoring_role = false` | Apply fails on the missing IAM role | Apply |

Keep `engine_version` major-only. RDS then selects the latest available minor,
and the provider treats the config as a prefix of the recorded version, so there
is no perpetual diff.

## One logical database, and the role has to already exist

br-sisbajud is a **single-service** chart: one Go binary (HTTP API plus
background workers in one process) against **one** database. There is no
onboarding/transaction split, so unlike `products/midaz/postgres` this root DOES
emit the database name.

| Terraform | Chart key |
|---|---|
| `endpoint` | `POSTGRES_HOST` |
| `port` | `POSTGRES_PORT` |
| `username` | `POSTGRES_USER` |
| `database_name` | `POSTGRES_NAME` |
| `secret_name` -> External Secrets | `POSTGRES_PASSWORD` |

**`database_name` and `username` default to `br_sisbajud`, with an underscore.**
Two separate reasons, and both matter:

- *Underscore, not hyphen.* The AWS resource is `br-sisbajud-{env}-postgres`, but
  a PostgreSQL identifier containing a hyphen has to be quoted in every DSN and
  every migration, and the lib-commons migrator does not quote it. A validation on
  `database_name` rejects anything that is not a bare identifier.
- *The role is not created by anything else.* Nothing in the chart creates an
  application role. The PreSync migration Job connects as
  `brSisbajud.configmap.POSTGRES_USER` (chart default `br_sisbajud`) with
  `brSisbajud.secrets.POSTGRES_PASSWORD`, and that role must already exist. Making
  the RDS master user the one the chart expects is what lets a fresh instance take
  the first migration. Least-privilege per-service roles are created on the
  instance afterwards, outside Terraform.

### The 1.0.1 rename

Chart 1.0 called these `POSTGRES_DATABASE` and `POSTGRES_SSL_MODE`. Chart 1.0.1
renamed them to **`POSTGRES_NAME`** and **`POSTGRES_SSLMODE`** to match the
lib-commons migrator (`docs/UPGRADE-1.0.1.md:68,81`). The old names are dead —
emitting them loses the database name with no error.

### `POSTGRES_SSLMODE` is not emitted

It is a client policy decision, not an infrastructure fact: RDS accepts TLS on
every instance and the chart default is `disable`. Note the second half of that
decision, which is easy to miss: the lib-commons migrator **refuses non-TLS
Postgres unless `ALLOW_INSECURE_TLS` is true** — `sslmode=disable` alone is not
enough (`templates/migrations/job.yaml:19-23`). A dev tier on plaintext needs
both.

## Read replica

`create_read_replica = true` publishes `replica_endpoint`, the raw RDS hostname of
the replica.

**It is not wired into `helm_values`, because this chart has no replica
variable.** `products/midaz/postgres` emits `DB_*_REPLICA_HOST` and falls back to
the primary; that is a midaz-chart fact, not a Lerian-wide one. Inventing a
replica variable here would produce a key the container ignores.

## Outputs

Seven uniform contract names shared with every other Lerian datastore root —
`mode`, `endpoint`, `port`, `security_group_id`, `secret_arn`, `secret_name`,
`identifier` — plus `database_name`, `username`, `replica_*`,
`subnet_group_name`, the cross-stack context (`vpc_name`, `eks_cluster_name`,
`ingress_*`), and `helm_values`.

`endpoint` is the raw RDS hostname in both modes. There is no `dns_name`: the
RDS certificate covers `*.{region}.rds.amazonaws.com`, so an alias in front of
it would break TLS hostname verification for any client that validates it.

```bash
terraform output -json helm_values | jq
```

No password is ever an output. `secret_name` is what an External Secrets
Operator `ExternalSecret` references to populate `POSTGRES_PASSWORD` — which the
chart marks **required** for external Postgres (`values-template.yaml:28`) and
which the PreSync migration Job pulls by `secretKeyRef`.

## Shared mode

`mode = "shared"` creates nothing and plans to zero resources. Every lookup in
this root is gated on `mode == "dedicated"`, so the VPC does not even need to
exist. The module resolves the instance `shared-{env}-postgres` with
`data "aws_db_instance"` and the secret `shared-{env}-postgres/password` with
`data "aws_secretsmanager_secret"`; `endpoint`, `port`, `username` and
`database_name` then come from the resolved instance rather than from this
stack's variables. `security_group_id` comes back `null`: opening the shared
instance is `products/shared-resources/postgres`' job.

The name is fully derived, so this root exposes no variable for it. The module's
own `shared_identifier` is the escape hatch for a shared instance that is not
called `shared-{env}-postgres`.

Every sizing variable in the tfvars is ignored in that mode.
