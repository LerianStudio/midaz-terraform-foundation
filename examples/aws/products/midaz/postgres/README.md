# products/midaz/postgres

PostgreSQL for the midaz ledger. Root stack over
[`_modules/postgres-rds`](../../../_modules/postgres-rds).

One root, one datastore, one state file. See [`../README.md`](../README.md) for
the product-level picture: deploy order, the shared-vs-dedicated model, and the
full Helm mapping.

| | |
|---|---|
| Module | `../../../_modules/postgres-rds` |
| State key | `aws/products/midaz/postgres/terraform.tfstate` |
| Creates | `midaz-{env}-postgres` (RDS instance) |
| Secret | `midaz-{env}-postgres/password` |
| Chart target | `ledger.configmap` (`DB_ONBOARDING_*`, `DB_TRANSACTION_*`) |

## Run it

```bash
cd examples/aws/products/midaz/postgres

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/midaz/postgres/terraform.tfstate"

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
   Note the `lerian` prefix on both: they belong to `infra-base`, not to midaz.
   That is also why this root does **not** call the `naming` module — seeding it
   with `product = "midaz"` would derive `midaz-{env}-vpc`, which does not
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

## Two logical databases, one instance

midaz runs `onboarding` and `transaction` on the same instance. RDS creates
exactly one database at provisioning time (`database_name`, default `midaz`); the
second is created by the application migration.

That is why `helm_values` does **not** emit `DB_ONBOARDING_NAME` or
`DB_TRANSACTION_NAME` — Terraform does not know them and must not guess. The
chart defaults (`onboarding`, `transaction`) are correct; leave them alone.

## Read replica

`create_read_replica = true` publishes `replica_endpoint` — the raw RDS hostname
of the replica — and points the chart's `DB_*_REPLICA_HOST` at it.

With no replica, `helm_values` points those variables at the **primary**. That is
deliberate: the ledger opens a second connection pool from them regardless, and
the chart's own default (`midaz-postgresql-replication`) is a subchart service
that stops existing the moment `postgresql.enabled` is false. Leaving them unset
breaks the pool; pointing them at the primary works and just puts the read pool
on the writer.

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
Operator `ExternalSecret` references to populate `DB_ONBOARDING_PASSWORD` and
`DB_TRANSACTION_PASSWORD`.

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
