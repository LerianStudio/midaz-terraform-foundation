# products/plugin-br-pix-direct-jd/postgres

PostgreSQL for plugin-br-pix-direct-jd — the Pix Direto rail over the JD partner
interface. Root stack over
[`_modules/postgres-rds`](../../../_modules/postgres-rds).

One root, one datastore, one state file. See [`../README.md`](../README.md) for
the product-level picture: the three chart components, the shared-vs-dedicated
model, and the full Helm mapping.

| | |
|---|---|
| Module | `../../../_modules/postgres-rds` |
| State key | `aws/products/plugin-br-pix-direct-jd/postgres/terraform.tfstate` |
| Creates | `plugin-br-pix-direct-jd-{env}-postgres` (RDS instance) |
| Secret | `plugin-br-pix-direct-jd-{env}-postgres/password` |
| Chart target | `.Values.pix.configmap` (`DATABASE_*`) — **which also drives the CronJob** |

## Run it

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

Prerequisites: `infra-base/vpc`. `infra-base/eks` is optional at apply time —
see *Ingress* below.

## What this root decides

The module already resolves the VPC and the subnets by itself. This root exists
for three things the module cannot do:

1. **Derive the cross-stack names.** `lerian-{env}-vpc` and `lerian-{env}-eks`.
   Note the `lerian` prefix: they belong to `infra-base`. That is why this root
   does **not** call the `naming` module.
2. **Compute the ingress allow list.**
3. **Translate to the chart.** The `helm_values` output.

It creates no AWS resource of its own.

## Ingress

Performed by
[`_modules/product-network`](../../../_modules/product-network), called here as
`module.network` with `enabled = var.mode == "dedicated"`.

Two sources, merged and handed to the module:

- **`Type=private` subnet CIDRs** (`allow_private_subnet_cidr_ingress`, default
  true). Depends only on `infra-base/vpc`, so it works from the first apply.
- **the EKS node security group**, matched by
  `tag:Name = "lerian-{env}-eks-node"`, resolved with the **plural**
  `data "aws_security_groups"`. `check "eks_node_security_group_resolved"` warns
  while the lookup is empty.

One allow list covers **both** workloads that touch the database — the `pix`
Deployment and the CronJob — because they run on the same nodes.

> `var.subnet_tag_type` (`"database"`) selects the subnets the **instance is
> placed in** and goes to `postgres-rds` only. `product-network` keeps its own
> default (`"private"`), the subnets whose CIDRs become **ingress**.

The "nothing can reach this instance at all" case is **not** re-asserted here:
the module already carries `check "ingress_is_reachable"`.

## Sizing traps

| Trap | Consequence | Where it is caught |
|---|---|---|
| `performance_insights_enabled = true` on `db.t4g.micro` | AWS does not offer PI on t2/t3/t4g micro and small | Module precondition, at **plan** time |
| `engine_version = "16.3"` | AWS retired that minor; `Cannot find version 16.3 for postgres` | Only at apply, in a real account — hence MAJOR-only `"16"` |
| `monitoring_interval > 0` with `create_monitoring_role = false` | Apply fails on the missing IAM role | Apply |

## Terraform owns the database AND the role, because nothing else does

This chart ships **no bootstrap Job**. With the bundled Bitnami subchart, the
`pix` role and `pix` database came from the container entrypoint reading
`POSTGRES_USER` / `POSTGRES_DB`. Point the chart at an external RDS instance and
that mechanism disappears.

So `database_name = "pix"` (the chart default) is created by RDS at provisioning
time, and `username` is the RDS master — the only role that exists. If a DBA
later creates a least-privilege `pix` role, override `DATABASE_USER` in the
release rather than changing `username`, which renames the master and forces a
replacement.

## No read replica, on purpose

Unlike `products/midaz/postgres` and `products/plugin-br-payments/postgres`, this
root exposes no `create_read_replica`.

`grep -rniE "replica"` over `plugin-br-pix-direct-jd-helm` 3.0.0 returns forty
hits and not one is a database variable — all are Kubernetes pod replica counts,
HPA bounds, or a Bitnami `max_replication_slots` line. A replica would be an RDS
instance nothing could be pointed at. Add the chart variables first, then the
toggle.

## Outputs

Seven uniform contract names shared with every other Lerian datastore root —
`mode`, `endpoint`, `port`, `security_group_id`, `secret_arn`, `secret_name`,
`identifier` — plus `database_name`, `username`, `subnet_group_name`, the
cross-stack context (`vpc_name`, `eks_cluster_name`, `ingress_*`), and
`helm_values`. There is no `replica_*` pair, per the section above.

`endpoint` is the raw RDS hostname in both modes. There is no `dns_name`: the
RDS certificate covers `*.{region}.rds.amazonaws.com`.

```bash
terraform output -json helm_values | jq
```

**Merge the result into `pix.configmap`, once.** The CronJob's own ConfigMap
reads `.Values.pix.configmap.DATABASE_*`, not `.Values.job.configmap.*` — the
`job.configmap` keys are dead and setting them is a silent no-op.

No password is ever an output. `secret_name` feeds **two** chart keys,
`pix.secrets.DATABASE_PASSWORD` and `pix.secrets.POSTGRES_PASSWORD`, which the
deployment wires from the same source.

> The chart has **no** SSL-mode variable of any kind. Whether the driver
> negotiates TLS against RDS is decided in the application. Worth raising with
> the service owner — this is a Pix rail, and the sibling `plugin-br-payments`
> chart ships `POSTGRES_SSLMODE: "require"` for the same class of workload.

## Shared mode

`mode = "shared"` creates nothing and plans to zero resources. Every lookup is
gated on `mode == "dedicated"`, so the VPC does not even need to exist. The
module resolves `shared-{env}-postgres` with `data "aws_db_instance"` and
`shared-{env}-postgres/password` with `data "aws_secretsmanager_secret"`;
`endpoint`, `port`, `username` and `database_name` then come from the resolved
instance. `security_group_id` comes back `null`.

Every sizing variable in the tfvars is ignored in that mode.
