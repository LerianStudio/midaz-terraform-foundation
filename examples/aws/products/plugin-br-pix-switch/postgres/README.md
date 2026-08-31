# products/plugin-br-pix-switch/postgres

PostgreSQL for the plugin-br-pix-switch umbrella — seven of the chart's ten
components ride this one instance, across three databases. Root stack over
[`_modules/postgres-rds`](../../../_modules/postgres-rds).

One root, one datastore, one state file. See [`../README.md`](../README.md) for
the product-level picture: deploy order, the shared-vs-dedicated model, and the
full Helm mapping.

| | |
|---|---|
| Module | `../../../_modules/postgres-rds` |
| State key | `aws/products/plugin-br-pix-switch/postgres/terraform.tfstate` |
| Creates | `plugin-br-pix-switch-{env}-postgres` (RDS instance) |
| Secret | `plugin-br-pix-switch-{env}-postgres/password` |
| Chart target | `global.externalPostgresDefinitions` (**value paths**, not env vars) |
| Chart verified | plugin-br-pix-switch 2.0.0-beta.1+ |

## Run it

```bash
cd examples/aws/products/plugin-br-pix-switch/postgres

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/plugin-br-pix-switch/postgres/terraform.tfstate"

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
   Note the `lerian` prefix on both: they belong to `infra-base`, not to plugin-br-pix-switch.
   That is also why this root does **not** call the `naming` module — seeding it
   with `product = "plugin-br-pix-switch"` would derive `plugin-br-pix-switch-{env}-vpc`, which does not
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

## The chart consumes DSNs, not host/port — so `helm_values` looks different

**This is the structural difference from every other product in the repository.**
Read it before copying anything from `products/midaz/postgres`.

Every component reads Postgres through two **full connection URLs**, and both
live under `<component>.secrets`:

```yaml
spi:
  secrets:
    DATABASE_URL:             "postgres://pixswitch:<password>@host:5432/pix-spi?sslmode=require"
    SYSTEMPLANE_POSTGRES_DSN: "postgres://pixswitch:<password>@host:5432/pix-spi?sslmode=require"
```
(`values-template.yaml:42-43`, repeated for `spiSystemplane`, `dictHub`,
`dictHubVsync`, `dictSystemplane`, `cobHub`, `cobSystemplane`)

There is **no** `POSTGRES_HOST`, no `POSTGRES_PORT`, no `POSTGRES_USER` in the
component surface. `<component>.secrets` is emitted verbatim into a Secret
(`templates/spi/secrets.yaml:13-15`) and that is the whole contract.

Terraform cannot fill a secret — a DSN carries the password, and this repository
never emits a password. So this root publishes two things instead:

1. **`helm_values`** — the non-secret surface, keyed by **Helm value path**
   rather than env var name, because that is what these are:

   | Path | Value |
   |---|---|
   | `global.externalPostgresDefinitions.connection.host` | `endpoint` |
   | `global.externalPostgresDefinitions.connection.port` | `port` |
   | `global.externalPostgresDefinitions.postgresAdminLogin.username` | `username` |

2. **`database_url_templates`** — one DSN per application database, with the
   password left as the literal placeholder `<password>`:

   ```bash
   terraform output -json database_url_templates | jq
   ```

## Three databases, created by the chart

`pix-spi`, `pix-dict` and `pix-cob` (`values.yaml:68-71`). **The chart creates
them**, from a bootstrap Job it ships under
`global.externalPostgresDefinitions`, one Job per database
(`templates/bootstrap-postgres.yaml`). Each Job:

- connects as the **admin** account to the hardcoded `postgres` maintenance
  database (`DB_DATABASE: postgres`),
- `CREATE ROLE "pixswitch" LOGIN PASSWORD ...` if it does not exist,
- `CREATE DATABASE "pix-spi" OWNER "pixswitch"` if it does not exist,
- grants on the database, the `public` schema, its tables and its sequences,
  plus matching `ALTER DEFAULT PRIVILEGES`.

It is idempotent — it checks `pg_roles` and `pg_database` first — and it is off
by default (`enabled: false`).

Two consequences for this root:

- **`database_name` here is not one of them.** It is the instance's initial
  database (`pixswitch`) and nothing in the release reads it. The Job uses the
  `postgres` maintenance database, which RDS always provides.
- **`username` stays `postgres`**, because that is the ADMIN account the Job
  authenticates with, and `postgresAdminLogin.username` defaults to exactly that
  (`values.yaml:79`). The **application** role — `pixswitch` — is created *by the
  Job* with a password the operator supplies. It is a different credential from
  the one behind `secret_name`, and mixing them up is the easiest mistake to make
  here.

> The chart says it plainly: *"Never put real admin passwords in values.yaml"*
> (`values.yaml:61`). Use
> `global.externalPostgresDefinitions.postgresAdminLogin.useExistingSecret.name`
> and point it at a Secret populated from `secret_name` by External Secrets.

## The generated password is URL-safe — FIXED UPSTREAM

This used to be the cross-cutting trap of the whole product: every datastore is
reached through a connection **URL**, so every generated password is
interpolated into one.

The shared modules were narrowed to the RFC 3986 §2.3 *unreserved* set, which
needs no percent-encoding in any position of a URI:

| Module | Was | Now | Length |
|---|---|---|---|
| `_modules/postgres-rds` | `!#$%^&*()-_=+[]{}<>:?` — `#` `%` `?` `:` | `-_.~` | 16 → **32** |
| `_modules/mongodb-documentdb` | `!#$^&*()-_=+[]{}<>?` — `#` `$` `?` | `-_.~` | 16 → **32** |
| `_modules/rabbitmq-amazonmq` | `!#$%^&*()-_+{}<>?` — `#` `%` `?` | `-_.~` | 16 → **32** |
| `_modules/valkey-elasticache` | `` !#$%&'()*+,-.:<=>?[]^_`{|}~ `` | **`-`** (ElastiCache allowlist ∩ unreserved) | 32 |

`#` truncated the URL at the fragment, `%` started an invalid percent-escape,
`?` opened a query string and `:` broke the userinfo split. Over 16 characters,
hitting at least one was the likely outcome rather than the edge case — and the
failure was not always clean: the client could connect somewhere unintended
instead of erroring.

Nothing to percent-encode and nothing to rotate by hand. Rationale and the
per-engine limit checks live in each module's README; the product-level summary
is in [`../README.md`](../README.md).

> **One-time migration cost.** The narrowing regenerates the password, so the
> first `apply` after this change **rotates** the RDS master credential. Roll it
> dev → stg → prd, in a window.

## Read replica

`create_read_replica = true` publishes `replica_endpoint`, the raw RDS hostname of
the replica.

**It is not wired anywhere.** No component names a read-only DSN, and
`<component>.secrets` is a verbatim passthrough — a replica DSN would be an
operator-composed value. `database_url_templates` covers the writer only.

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

No password is ever an output. `secret_name` holds the **admin** password — what
the chart's bootstrap Job authenticates with. The **application** role's password
is not created here; it is whatever the operator gives
`global.externalPostgresDefinitions.pixswitchCredentials`, and it is the one that
goes into the DSNs.

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
