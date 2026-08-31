# products/br-sfn/postgres

PostgreSQL for the br-sfn SFN rails monorepo — SPB/STR, SPI/Pix, SILOC, SCR,
desk and correios all ride this one instance. Root stack over
[`_modules/postgres-rds`](../../../_modules/postgres-rds).

One root, one datastore, one state file. See [`../README.md`](../README.md) for
the product-level picture: deploy order, the shared-vs-dedicated model, and the
full Helm mapping.

| | |
|---|---|
| Module | `../../../_modules/postgres-rds` |
| State key | `aws/products/br-sfn/postgres/terraform.tfstate` |
| Creates | `br-sfn-{env}-postgres` (RDS instance) |
| Secret | `br-sfn-{env}-postgres/password` |
| Chart target | every rail's `<component>.configmap` (`POSTGRES_*`) |
| Chart verified | br-sfn 1.1.0, appVersion `1.0.0-beta.1` |

## Run it

```bash
cd examples/aws/products/br-sfn/postgres

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/br-sfn/postgres/terraform.tfstate"

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
   Note the `lerian` prefix on both: they belong to `infra-base`, not to br-sfn.
   That is also why this root does **not** call the `naming` module — seeding it
   with `product = "br-sfn"` would derive `br-sfn-{env}-vpc`, which does not
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

## One instance, one database per rail — and Terraform creates one of them

br-sfn is a **monorepo of independent rails**, each of which owns its own schema
and its own PreSync migration Job:

| Rail | Values key | Database key it reads |
|---|---|---|
| SPB/STR (TED) | `spb` | `POSTGRES_DB` |
| SPI/Pix (api, dict, brcode, core) | `spi` | `POSTGRES_DB` (shared by all four) |
| SILOC | `siloc` | `POSTGRES_DB` |
| SCR | `scr` | `POSTGRES_DB` |
| desk | `desk` | `POSTGRES_DB` |
| correios | `correios` | **`POSTGRES_NAME`** |

RDS creates **exactly one** database at provisioning time. `database_name` here
is therefore the **bootstrap** database (`br_sfn`), and the per-rail databases
are created on the instance afterwards, outside Terraform.

That is why `helm_values` emits only `POSTGRES_HOST`, `POSTGRES_PORT` and
`POSTGRES_USER` — Terraform does not know the rail database names and must not
guess them.

> **`correios` reads `POSTGRES_NAME`, every other rail reads `POSTGRES_DB`.**
> Not a typo: `templates/correios/migrations-job.yaml:3` passes
> `dbCfgKey = "POSTGRES_NAME"` to the shared migration helper, which otherwise
> defaults to `POSTGRES_DB` (`templates/_helpers.tpl:483`). Both sides of the
> contract agree on it; do not "fix" one of them.

The keys are **per-component**. There is no chart-wide configmap — merge the map
into each enabled rail's own `configmap:` block. SPI takes it once, under
`spi.configmap`, which the four SPI components share.

Host, user and database are all **required** by the migration helper, which
`fail`s the render when any is missing (`templates/_helpers.tpl:474-490`). That
is a good failure: it happens at template time, not at connect time.

## The generated password is URL-safe — FIXED UPSTREAM

**This used to be the one cross-cutting trap in this product. It is closed.**

The br-sfn chart states the rule plainly: *"Postgres passwords must be URL-safe
(no `@ : / ? # %`)"* (`README.md:51`). It has to, because the baked-flavour
migration Jobs interpolate the password straight into a connection URL with no
escaping:

```
-database "postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}?sslmode=${POSTGRES_SSLMODE}"
```
(`templates/_helpers.tpl:604`)

`_modules/postgres-rds` **used to** generate the master password with
`override_special = "!#$%^&*()-_=+[]{}<>:?"` — which includes `#`, `%`, `?` and
`:`, four of the six characters the chart forbids. Over 16 characters, hitting
at least one was the likely outcome, not the edge case.

The failure was not clean either. `#` truncates the URL at the fragment, `%`
starts an invalid percent-escape, `?` opens a query string and `:` breaks the
userinfo split — so the migration Job would fail with a parse error or, worse,
silently connect somewhere unintended.

**The module was fixed rather than worked around here**, because the password
belongs to the module and the module is shared with every other product. It now
generates **32 characters** over alphanumerics plus `-_.~`, the RFC 3986 §2.3
*unreserved* set — none of which needs percent-encoding in any position of a
URI, and none of which appears on the chart's forbidden list. Rationale and the
RDS limit checks are in
[`_modules/postgres-rds/README.md`](../../../_modules/postgres-rds/README.md).

Nothing to check before the first apply, and nothing to mitigate. The
`dedicated`-flavour migrator images that take the `POSTGRES_*` env contract
instead of building a URL remain a fine choice on their own merits, but no
longer for this reason.

> **One-time migration cost.** Narrowing the set regenerates the password, so
> the first `apply` after this change **rotates** the RDS master credential.
> Workloads holding the old value fail authentication until External Secrets
> resyncs and the pods restart. Roll it dev → stg → prd, in a window.

## Read replica

`create_read_replica = true` publishes `replica_endpoint`, the raw RDS hostname of
the replica.

**It is not wired into `helm_values`.** No rail in this chart names a replica
variable, and component configmaps are passed through verbatim, so a replica key
would be an operator-supplied name this stack cannot know.

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
Operator `ExternalSecret` references to populate each rail's
`POSTGRES_PASSWORD` — required for every rail except `slcEdge` and `cockpit`,
which have no database. It is URL-safe by construction; see *The generated
password is URL-safe — FIXED UPSTREAM* above for what changed and for the
one-time rotation the first apply performs.

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
