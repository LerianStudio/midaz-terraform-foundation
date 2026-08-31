# products/plugin-br-pix-jd/postgres

PostgreSQL for the Pix integration over the JD partner interface. Root stack
over [`_modules/postgres-rds`](../../../_modules/postgres-rds).

One root, one datastore, one state file — and the only service root this product
has.

> **⚠ The plugin-br-pix-jd chart is not in this repository.** `helm_values` is
> deliberately **empty**. Read [`../README.md`](../README.md) before using this
> stack for anything beyond a dev sandbox.

| | |
|---|---|
| Module | `../../../_modules/postgres-rds` |
| State key | `aws/products/plugin-br-pix-jd/postgres/terraform.tfstate` |
| Creates | `plugin-br-pix-jd-{env}-postgres` (RDS instance) |
| Secret | `plugin-br-pix-jd-{env}-postgres/password` |
| Chart target | **unknown** — see below |

## Why `helm_values` is empty

`infrastructure/K8S/helm/charts/plugin-br-pix-jd/` has no `Chart.yaml`, no
`values.yaml` and no `templates/` — only two vendored tarballs:

```
charts/postgresql-16.3.5.tgz          Bitnami postgresql
charts/lerian-common-helm-1.3.4.tgz   Lerian LIBRARY chart, type: library
```

The second one is Lerian-authored, which makes it tempting, and it is a dead end
by design. It declares `type: library`, *"renders nothing on its own"*, and its
`_datastore.tpl` helper takes the real env var name as a **caller-supplied
argument** — its own doc comment reads:

> `nativeKey (req) the product's real env key (e.g. DB_ONBOARDING_HOST)`

Even the shared Lerian library refuses to know what this product calls its
variables. The `DB_ONBOARDING_HOST` / `DB_LEDGER_HOST` / `DB_FEES_HOST` examples
in its docs belong to **other** products and must not be copied here.

Among the four readable Lerian charts, three PostgreSQL variable families are in
production use — `DB_ONBOARDING_*`, `DB_HOST`, and `POSTGRES_HOST` — with no
majority. A wrong name does not fail the plan, the render, or the pod start; it
produces a service quietly talking to the chart's in-cluster default while this
RDS instance sits idle.

`plugin-br-pix-jd` is a sibling of `plugin-br-pix-direct-jd`, which **does** have
a readable chart. That is the first place to look for a house style — but a
sibling's convention is a hypothesis, not a source.

`database_name` (default `"pixjd"`) is likewise an **infrastructure choice**, not
a fact read from anywhere. Confirm it with the owning team.

## Why there is no `valkey/` beside this

The absence of a `valkey` tarball is the same evidence as the presence of the
postgresql one, read the other way — and it matches
`product-infra-dependencies.yaml`, which records only `postgresql: yes` for this
product.

That is a reasonable reading of what someone vendored, not a statement from the
chart. Re-confirm it when the chart becomes available: if it turns out to read
`REDIS_*` or `STREAMING_*`, add the matching root then.

## Map it by hand

```bash
cd examples/aws/products/plugin-br-pix-jd/postgres
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
cd examples/aws/products/plugin-br-pix-jd/postgres

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/plugin-br-pix-jd/postgres/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

`../../../` is **three** levels up and lands on `examples/aws`. Verified with
`terraform init -backend=false`.

Prerequisites: `infra-base/vpc`. `infra-base/eks` is optional at apply time.

## What IS verified

The chart gap does not touch the infrastructure. This root is a sibling of the
tracer and br-consignado-gw postgres roots for everything that does not depend
on chart contents: naming and tagging, `module.network` resolution, the ingress
model, the `dedicated` / `shared` switch, the seven uniform outputs, sizing per
environment, and clean `terraform validate` / `tflint` / `trivy config`.

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

## Sizing traps

| Trap | Consequence | Caught |
|---|---|---|
| `performance_insights_enabled = true` on `db.t4g.micro` | AWS does not offer PI on t2/t3/t4g micro and small | Module precondition, at **plan** time |
| `engine_version = "16.3"` | AWS retired that minor; `Cannot find version 16.3 for postgres` | Only at apply, in a real account — hence MAJOR-only `"16"` |
| `monitoring_interval > 0` with `create_monitoring_role = false` | Apply fails on the missing IAM role | Apply |

## Read replica

Off in every environment. With the chart unavailable there is no way to confirm
the application can address a reader endpoint. `replica_endpoint` is published
for when that changes.

## Shared mode

`mode = "shared"` creates nothing and plans to zero resources. The module
resolves `shared-{env}-postgres` with `data "aws_db_instance"` and
`shared-{env}-postgres/password` with `data "aws_secretsmanager_secret"`;
`endpoint`, `port`, `username` and `database_name` then come from the resolved
instance. `security_group_id` comes back `null`.

Worth noting: in shared mode `database_name` becomes the **shared** instance's
initial database, not `"pixjd"`.

Every sizing variable in the tfvars is ignored in that mode.
