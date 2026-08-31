# products/tracer/postgres

PostgreSQL for the tracer validation engine — rules, spending limits and the
hash-chained audit trail. Root stack over
[`_modules/postgres-rds`](../../../_modules/postgres-rds).

One root, one datastore, one state file. See [`../README.md`](../README.md) for
the product-level picture: deploy order, the shared-vs-dedicated model, and the
full Helm mapping.

| | |
|---|---|
| Module | `../../../_modules/postgres-rds` |
| State key | `aws/products/tracer/postgres/terraform.tfstate` |
| Creates | `tracer-{env}-postgres` (RDS instance) |
| Secret | `tracer-{env}-postgres/password` |
| Chart target | `tracer.configmap` (`DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`) |

## Run it

```bash
cd examples/aws/products/tracer/postgres

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/tracer/postgres/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

`../../../` is **three** levels up and lands on `examples/aws`, where both
`backend/` and `_modules/` live. Verified with `terraform init -backend=false`.

Prerequisites: `infra-base/vpc`. `infra-base/eks` is optional at apply time —
see *Ingress* below.

## What this root decides

The module resolves the VPC and the subnets by itself. This root exists for
three things the module cannot do:

1. **Derive the cross-stack names.** `lerian-{env}-vpc` and `lerian-{env}-eks`.
   Note the `lerian` prefix: they belong to `infra-base`, not to tracer. That is
   also why this root does **not** call the `naming` module — seeding it with
   `product = "tracer"` would derive `tracer-{env}-vpc`, which does not exist.
2. **Compute the ingress allow list.**
3. **Translate to the chart.** The `helm_values` output.

It creates no AWS resource of its own.

## Ingress

Resolved by [`_modules/product-network`](../../../_modules/product-network),
called here as `module.network` with `enabled = var.mode == "dedicated"`. Two
sources, merged and handed to `postgres-rds`:

- **`Type=private` subnet CIDRs** (`allow_private_subnet_cidr_ingress`, default
  true). Depends only on `infra-base/vpc`, so it works from the first apply.
- **the EKS node security group**, matched by
  `tag:Name = "lerian-{env}-eks-node"` with the **plural**
  `data "aws_security_groups"`, so an absent cluster returns an empty list
  rather than failing the plan. `check "eks_node_security_group_resolved"` warns
  while the lookup is empty.

> `var.subnet_tag_type` (`"database"`) selects the subnets the **instance is
> placed in** and goes to `postgres-rds` only. `product-network` keeps its own
> default (`"private"`), the subnets whose CIDRs become **ingress**. Do not
> forward one into the other.

`allow_vpc_cidr_ingress` is `false`: it is a fallback the module applies only
when *both* allow lists resolve empty. The "nothing can reach this instance"
case is not re-asserted here — the module carries
`check "ingress_is_reachable"`.

## The chart has no PostgreSQL subchart, and that is a trap

The tracer chart declares **no `dependencies:` block at all**, so there is no
`postgresql.enabled: false` to set — nothing bundled to turn off.

But it still ships an in-cluster default host that nothing creates:

```yaml
# values.yaml:202
DB_HOST: "tracer-postgresql.tracer.svc.cluster.local."
```

Leaving `DB_HOST` unset therefore does not error; it aims the release at a
hostname that does not resolve, or at a hand-rolled Postgres someone left in the
namespace. **Wiring `helm_values` is mandatory here, not optional.**

## One logical database

Unlike midaz, tracer runs a single logical database. `database_name` (default
`"tracer"`) is complete, and `helm_values` therefore emits `DB_NAME` — which the
midaz root deliberately cannot, because RDS creates one database and midaz needs
two.

The chart agrees out of the box: `DB_NAME` defaults to `"tracer"`
(`values.yaml:204`).

## The username disagreement

`username` defaults to `"postgres"` — the RDS **master** user, the only role
that exists on a fresh instance, and what `helm_values` emits as `DB_USER`.

The chart's own default is `"tracer"` (`values.yaml:205`), a least-privilege
application role. Nothing in this repository creates it. Creating one is an
out-of-band step, exactly like the second logical database on the midaz
instance; until then the master user is the truthful answer.

## The optional bootstrap Job

The chart ships `templates/bootstrap-postgres.yaml`, off by default
(`values.yaml:12`), which creates the `tracer` database and role on an external
instance using an **admin** login.

It is deliberately not wired from `helm_values`: its `connection.host` and
`connection.port` take the same values as above, but its `postgresAdminLogin`
needs the RDS master credentials, and handing a Job the master password is an
operator decision, not a Terraform default. See the product README.

## Sizing traps

| Trap | Consequence | Caught |
|---|---|---|
| `performance_insights_enabled = true` on `db.t4g.micro` | AWS does not offer PI on t2/t3/t4g micro and small | Module precondition, at **plan** time |
| `engine_version = "16.3"` | AWS retired that minor; `Cannot find version 16.3 for postgres` | Only at apply, in a real account — which is why the default is MAJOR-only `"16"` |
| `monitoring_interval > 0` with `create_monitoring_role = false` | Apply fails on the missing IAM role | Apply |

Keep `engine_version` major-only. RDS then selects the latest available minor
and the provider treats the config as a prefix, so there is no perpetual diff.

## Read replica

Off in every environment, including prd. The tracer chart defines a single
`DB_HOST` and **no reader variable of any kind**, so a replica would be
provisioned with nothing able to address it. Turn it on only alongside a chart
that grows one; `replica_endpoint` is published for that day.

## Outputs

Seven uniform contract names shared with every Lerian datastore root — `mode`,
`endpoint`, `port`, `security_group_id`, `secret_arn`, `secret_name`,
`identifier` — plus `database_name`, `username`, `replica_*`,
`subnet_group_name`, the cross-stack context, and `helm_values`.

`endpoint` is the raw RDS hostname in both modes. There is no `dns_name`: the
RDS certificate covers `*.{region}.rds.amazonaws.com`, so an alias in front of
it breaks TLS hostname verification for any client that validates it.

```bash
terraform output -json helm_values | jq
```

No password is ever an output. `secret_name` is what an External Secrets
Operator `ExternalSecret` references to populate `tracer.secrets.DB_PASSWORD`.

`DB_SSL_MODE` is **not** emitted — a client policy decision, not an
infrastructure fact, and the same call the midaz root makes about its
`DB_*_SSLMODE`.

## Shared mode

`mode = "shared"` creates nothing and plans to zero resources. Every lookup is
gated on `mode == "dedicated"`, so the VPC does not even need to exist. The
module resolves `shared-{env}-postgres` with `data "aws_db_instance"` and the
secret `shared-{env}-postgres/password` with
`data "aws_secretsmanager_secret"`; `endpoint`, `port`, `username` and
`database_name` then come from the resolved instance. `security_group_id` comes
back `null`: opening the shared instance is
`products/shared-resources/postgres`' job.

The name is fully derived, so this root exposes no variable for it. The module's
own `shared_identifier` is the escape hatch for an instance not called
`shared-{env}-postgres`.

Every sizing variable in the tfvars is ignored in that mode.
