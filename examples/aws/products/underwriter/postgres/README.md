# products/underwriter/postgres

PostgreSQL for the underwriter (lender) product. Root stack over
[`_modules/postgres-rds`](../../../_modules/postgres-rds).

One root, one datastore, one state file.

> **⚠ The underwriter chart is not in this repository.** `helm_values` is
> deliberately **empty**. Read [`../README.md`](../README.md) before using this
> stack for anything beyond a dev sandbox.

| | |
|---|---|
| Module | `../../../_modules/postgres-rds` |
| State key | `aws/products/underwriter/postgres/terraform.tfstate` |
| Creates | `underwriter-{env}-postgres` (RDS instance) |
| Secret | `underwriter-{env}-postgres/password` |
| Chart target | **unknown** — see below |

## Why `helm_values` is empty

`infrastructure/K8S/helm/charts/underwriter/` has no `Chart.yaml`, no
`values.yaml` and no `templates/` — only `charts/postgresql-16.3.5.tgz` and
`charts/valkey-2.4.7.tgz`, both upstream Bitnami dependency charts.

Those tarballs prove the product *depends on* PostgreSQL. They say nothing about
how it *connects*, because they are the charts that stand a database pod up, not
the product's chart for addressing one.

Among the four readable Lerian charts, three different PostgreSQL variable
families are in production use:

| Chart | family |
|---|---|
| midaz | `DB_ONBOARDING_*` / `DB_TRANSACTION_*`, no plain `DB_HOST` |
| tracer | `DB_HOST` / `DB_PORT` / `DB_NAME` / `DB_USER` |
| plugin-access-manager | the same short `DB_*` family, on the `auth` component only |
| br-consignado-gw | `POSTGRES_HOST` / `POSTGRES_PORT` / `POSTGRES_USER` / `POSTGRES_NAME` |

There is no majority and no Lerian-wide convention to fall back on. And a wrong
name is the worst kind of wrong: it does not fail the plan, does not fail the
Helm render, and does not fail the pod start. It produces a service quietly
talking to the chart's in-cluster default while this RDS instance sits idle,
surfacing in production as data written to the wrong place.

`database_name` (default `"underwriter"`) is likewise an **infrastructure
choice**, not a fact read from anywhere. Confirm it with the owning team.

## Map it by hand

Everything a consumer needs is published as a first-class output:

```bash
cd examples/aws/products/underwriter/postgres
terraform output -raw endpoint
terraform output -raw port
terraform output -raw database_name
terraform output -raw username
terraform output -raw secret_name
```

No password is ever an output. `secret_name` is what an External Secrets
Operator `ExternalSecret` references.

## Run it

```bash
cd examples/aws/products/underwriter/postgres

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/underwriter/postgres/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

`../../../` is **three** levels up and lands on `examples/aws`. Verified with
`terraform init -backend=false`.

Prerequisites: `infra-base/vpc`. `infra-base/eks` is optional at apply time.

## What IS verified

The chart gap does not touch the infrastructure. This root is a byte-for-byte
sibling of the tracer and br-consignado-gw postgres roots for everything that
does not depend on chart contents:

- naming, tagging and the anti-collision contract;
- VPC / subnet / EKS-node-security-group resolution via `module.network`;
- the ingress model, the `dedicated` / `shared` switch, the seven uniform
  outputs;
- sizing per environment, copied from `products/midaz`;
- `terraform validate`, `tflint` and `trivy config` clean.

## Ingress

Resolved by [`_modules/product-network`](../../../_modules/product-network) as
`module.network`, `enabled = var.mode == "dedicated"`: `Type=private` subnet
CIDRs plus the EKS node security group matched by
`tag:Name = "lerian-{env}-eks-node"` with the **plural** data source, so an
absent cluster returns an empty list instead of failing the plan.

> `var.subnet_tag_type` (`"database"`) is the **placement** filter and goes to
> `postgres-rds` only. `product-network` keeps its own default (`"private"`),
> the **ingress** filter.

## Sizing traps

| Trap | Consequence | Caught |
|---|---|---|
| `performance_insights_enabled = true` on `db.t4g.micro` | AWS does not offer PI on t2/t3/t4g micro and small | Module precondition, at **plan** time |
| `engine_version = "16.3"` | AWS retired that minor; `Cannot find version 16.3 for postgres` | Only at apply, in a real account — hence MAJOR-only `"16"` |
| `monitoring_interval > 0` with `create_monitoring_role = false` | Apply fails on the missing IAM role | Apply |

## Read replica

Off in every environment. With the chart unavailable there is no way to confirm
the application can address a reader endpoint; turning it on would provision an
instance nothing talks to. `replica_endpoint` is published for when that
changes.

## Shared mode

`mode = "shared"` creates nothing and plans to zero resources. The module
resolves `shared-{env}-postgres` with `data "aws_db_instance"` and
`shared-{env}-postgres/password` with `data "aws_secretsmanager_secret"`;
`endpoint`, `port`, `username` and `database_name` then come from the resolved
instance. `security_group_id` comes back `null`.

Worth noting: in shared mode `database_name` becomes the **shared** instance's
initial database, not `"underwriter"` — one more reason to confirm what the
application actually expects before running this anywhere real.

Every sizing variable in the tfvars is ignored in that mode.
