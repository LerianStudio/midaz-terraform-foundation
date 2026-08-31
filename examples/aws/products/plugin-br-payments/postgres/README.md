# products/plugin-br-payments/postgres

PostgreSQL for plugin-br-payments — records, idempotency and outbox. Root stack
over [`_modules/postgres-rds`](../../../_modules/postgres-rds).

One root, one datastore, one state file. See [`../README.md`](../README.md) for
the product-level picture: why this is the ONLY datastore (ADR-002 and ADR-003),
the shared-vs-dedicated model, and the full Helm mapping.

| | |
|---|---|
| Module | `../../../_modules/postgres-rds` |
| State key | `aws/products/plugin-br-payments/postgres/terraform.tfstate` |
| Creates | `plugin-br-payments-{env}-postgres` (RDS instance) |
| Secret | `plugin-br-payments-{env}-postgres/password` |
| Chart target | `.Values.app.configmap` (`POSTGRES_*`) |

## Run it

```bash
cd examples/aws/products/plugin-br-payments/postgres

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/plugin-br-payments/postgres/terraform.tfstate"

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
   Note the `lerian` prefix on both: they belong to `infra-base`. That is why
   this root does **not** call the `naming` module — seeding it with
   `product = "plugin-br-payments"` would derive
   `plugin-br-payments-{env}-vpc`, which does not exist.
2. **Compute the ingress allow list.** Which sources may reach the database is a
   decision about the EKS cluster, not about the database.
3. **Translate to the chart.** The `helm_values` output.

It creates no AWS resource of its own.

## Ingress

Steps 1 and 2 are performed by
[`_modules/product-network`](../../../_modules/product-network), called here as
`module.network` with `enabled = var.mode == "dedicated"`.

Two sources, merged and handed to the module:

- **`Type=private` subnet CIDRs** (`allow_private_subnet_cidr_ingress`, default
  true). Depends only on `infra-base/vpc`, so it works from the first apply.
  Strictly tighter than the module's VPC-CIDR fallback, which would also cover
  the public subnets.
- **the EKS node security group**, matched by
  `tag:Name = "lerian-{env}-eks-node"`, resolved with the **plural**
  `data "aws_security_groups"` so an absent cluster returns an empty list rather
  than failing the plan. `check "eks_node_security_group_resolved"` warns while
  the lookup is empty; a warning that survives into steady state is the signal.

> `var.subnet_tag_type` (`"database"`) selects the subnets the **instance is
> placed in** and goes to `postgres-rds` only. `product-network` keeps its own
> default (`"private"`), the subnets whose CIDRs become **ingress**. Do not
> forward one into the other.

`allow_vpc_cidr_ingress` is `false` here — a fallback the module applies only
when *both* allow lists resolve empty.

The "nothing can reach this instance at all" case is **not** re-asserted here:
the module already carries `check "ingress_is_reachable"`.

## Sizing traps

| Trap | Consequence | Where it is caught |
|---|---|---|
| `performance_insights_enabled = true` on `db.t4g.micro` | AWS does not offer PI on t2/t3/t4g micro and small | Module precondition, at **plan** time |
| `engine_version = "16.3"` | AWS retired that minor; `Cannot find version 16.3 for postgres` | Only at apply, in a real account — which is why the default is MAJOR-only `"16"` |
| `monitoring_interval > 0` with `create_monitoring_role = false` | Apply fails on the missing IAM role | Apply |

## One logical database, and Terraform creates it

`database_name` defaults to `plugin_br_payments`, which is exactly the chart's
own `POSTGRES_DB`. RDS creates it at provisioning time, so the chart's optional
bootstrap Job (`global.externalPostgresDefinitions`, default off) has nothing
left to do.

That is why — unlike `products/midaz/postgres`, which runs two logical databases
and emits neither name — `helm_values` **does** emit `POSTGRES_DB`.

`username` stays `postgres`, the RDS master, which is also the `DB_USER_ADMIN`
that bootstrap Job expects. The chart's least-privilege default
`plugin_br_payments` is a role a DBA creates; override `POSTGRES_USER` in the
release once it exists rather than changing `username`, which renames the RDS
master and forces a replacement.

## Read replica

`create_read_replica = true` publishes `replica_endpoint` and makes `helm_values`
emit `POSTGRES_REPLICA_HOST` / `_PORT` / `_USER` / `_DB`.

**With no replica the keys are omitted entirely** — the opposite of what
`products/midaz/postgres` does, and correct for this chart. The application
resolves "replica DSN or primary" when `POSTGRES_REPLICA_HOST` is empty, and it
validates conditionally: any single `POSTGRES_REPLICA_*` value makes
`POSTGRES_REPLICA_HOST` mandatory. Setting them by hand to the primary would
move the read pool onto the writer for no benefit.

`POSTGRES_REPLICA_PASSWORD` is not emitted — a read replica inherits the master
credentials, so point External Secrets at the same `secret_name`.

## Outputs

Seven uniform contract names shared with every other Lerian datastore root —
`mode`, `endpoint`, `port`, `security_group_id`, `secret_arn`, `secret_name`,
`identifier` — plus `database_name`, `username`, `replica_*`,
`subnet_group_name`, the cross-stack context (`vpc_name`, `eks_cluster_name`,
`ingress_*`), and `helm_values`.

`endpoint` is the raw RDS hostname in both modes. There is no `dns_name`: the
RDS certificate covers `*.{region}.rds.amazonaws.com`, so an alias in front of it
would break TLS hostname verification — which matters here, because the chart
ships `POSTGRES_SSLMODE: "require"`.

```bash
terraform output -json helm_values | jq
```

No password is ever an output. `secret_name` is what an External Secrets
Operator `ExternalSecret` references to populate `app.secrets.POSTGRES_PASSWORD`.

## Shared mode

`mode = "shared"` creates nothing and plans to zero resources. Every lookup is
gated on `mode == "dedicated"`, so the VPC does not even need to exist. The
module resolves `shared-{env}-postgres` with `data "aws_db_instance"` and
`shared-{env}-postgres/password` with `data "aws_secretsmanager_secret"`;
`endpoint`, `port`, `username` and `database_name` then come from the resolved
instance. `security_group_id` comes back `null`.

The name is fully derived, so this root exposes no variable for it. The module's
own `shared_identifier` is the escape hatch for a shared instance not called
`shared-{env}-postgres`.

Every sizing variable in the tfvars is ignored in that mode.

> Weigh it harder here than elsewhere: this instance is on the payment hot path,
> not just its storage. Every inbound payment does an idempotency lookup and an
> outbox insert against it.
