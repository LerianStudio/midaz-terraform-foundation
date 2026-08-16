# products/plugin-access-manager/postgres

The **Casdoor backing store** — users, organisations, applications and Casbin
policies for every Lerian product that authenticates through the access manager.
Root stack over [`_modules/postgres-rds`](../../../_modules/postgres-rds).

One root, one datastore, one state file. See [`../README.md`](../README.md) for
the product-level picture: the three components, the aliased subchart, and the
full Helm mapping.

| | |
|---|---|
| Module | `../../../_modules/postgres-rds` |
| State key | `aws/products/plugin-access-manager/postgres/terraform.tfstate` |
| Creates | `plugin-access-manager-{env}-postgres` (RDS instance) |
| Secret | `plugin-access-manager-{env}-postgres/password` |
| Chart target | `auth.configmap` **only** (`DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`) |

## Run it

```bash
cd examples/aws/products/plugin-access-manager/postgres

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/plugin-access-manager/postgres/terraform.tfstate"

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

## `DB_NAME` must be `casdoor` — it is not configurable

Not a convention, a hard constraint.
`templates/auth-backend/configmap.yaml:10` hard-codes `dbName: casdoor` as a
literal in Casdoor's Beego config. It is **not templated from any values key**
and cannot be overridden from Helm.

`values.yaml:287` (`auth.configmap.DB_NAME`) and `values.yaml:417`
(`auth-database.auth.database`) agree. Changing `database_name` in the tfvars
breaks Casdoor itself, not just the wiring — which is why the variable's
description says so.

## One ConfigMap, three consumers

Everything `helm_values` produces goes into `auth.configmap` and **nowhere
else**:

| Consumer | How it gets the values |
|---|---|
| `auth` Deployment | its own ConfigMap |
| `auth-backend` (Casdoor) Deployment | `configMapKeyRef` against the **auth** ConfigMap (`templates/auth-backend/deployment.yaml:74-98`) |
| `templates/auth-backend/migrations.yaml` Job | same |
| `templates/auth/init_user.yaml` Job | same |
| `identity` Deployment | **has no database variables at all** |

`auth-backend` has no database ConfigMap of its own. It assembles Casdoor's
connection string in a shell command at container start
(`templates/auth-backend/deployment.yaml:68`):

```sh
export dataSourceName="user=${DB_USER} password=${DB_PASSWORD} host=${DB_HOST} port=${DB_PORT} sslmode=${DB_SSLMODE} dbname=${DB_NAME}"
```

Setting these keys on `identity.configmap` does nothing.

## Turning the bundled subchart off

```yaml
auth-database:
  enabled: false     # values.yaml:405
```

> **`auth-database`, not `postgresql`.** The dependency is Bitnami's
> `postgresql` chart under an **alias** (`Chart.yaml:32-36`), so
> `postgresql.enabled: false` sets a key nothing reads and the in-cluster
> database deploys anyway, beside the RDS instance nobody talks to.

### Where `DB_PASSWORD` comes from

`templates/_helpers.tpl:168-196` (`plugin-auth.dbPasswordEnv`) resolves it in
this order:

1. `auth-database.auth.existingSecret` → key `password`
2. otherwise, if the subchart is internal → the subchart's own generated Secret
3. otherwise → `auth.secrets.DB_PASSWORD`, key `DB_PASSWORD`

With RDS, point the External Secrets Operator at `secret_name` and use path 1 or
3. Note `auth-database.external` is a **template-consumed flag that is not
declared in `values.yaml`** — it appears only in a comment at `values.yaml:303`
and has to be added by hand. See the product README.

Note also that the two Jobs name the same value **`DB_PASS`**, not
`DB_PASSWORD`.

## The username disagreement

`username` defaults to `"postgres"` — the RDS **master** user, the only role
that exists on a fresh instance, and what `helm_values` emits as `DB_USER`.

The chart's default is `"auth"` (`values.yaml:284`), the role the bundled
Bitnami subchart creates. On RDS that role does not exist until someone creates
it. Creating a least-privilege role is an out-of-band step.

Related and worth not confusing with it: `USER_EXECUTE_COMMAND`, which the auth
ConfigMap defaults to `"postgres"` (`templates/auth/configmap.yaml:80`). It
happens to match this stack's master username, but it is an application setting
and is not emitted from here.

## `DB_SSLMODE` and its spelling drift

Not emitted — a client policy decision, not an infrastructure fact, and the same
call the midaz root makes about its `DB_*_SSLMODE`. Chart default `"disable"`
(`values.yaml:288`).

When setting it by hand, mind the drift: the ConfigMap key is **`DB_SSLMODE`**,
the auth-backend migrations Job reads `DB_SSLMODE`, and
`templates/auth/init_user.yaml:76` exposes the same value to its container as
**`DB_SSL_MODE`**, with the underscore.

## Blast radius

This is the one instance in this batch that a migration cannot rebuild. It holds
the identity data of every product that authenticates through Casdoor —
including `br-consignado-gw`, which consumes it as an external IdP.

`deletion_protection = true` and `skip_final_snapshot = false` in prd are not
boilerplate here.

## Sizing traps

| Trap | Consequence | Caught |
|---|---|---|
| `performance_insights_enabled = true` on `db.t4g.micro` | AWS does not offer PI on t2/t3/t4g micro and small | Module precondition, at **plan** time |
| `engine_version = "16.3"` | AWS retired that minor; `Cannot find version 16.3 for postgres` | Only at apply, in a real account — hence MAJOR-only `"16"` |
| `monitoring_interval > 0` with `create_monitoring_role = false` | Apply fails on the missing IAM role | Apply |

## Read replica

Off in every environment. Casdoor opens one connection string built from
`DB_HOST`/`DB_PORT`/`DB_USER`/`DB_NAME`/`DB_SSLMODE`
(`templates/auth-backend/deployment.yaml:68`) and has no reader variable to
point at a replica. `replica_endpoint` is published for the day one appears.

## Outputs

Seven uniform contract names — `mode`, `endpoint`, `port`, `security_group_id`,
`secret_arn`, `secret_name`, `identifier` — plus `database_name`, `username`,
`replica_*`, `subnet_group_name`, the cross-stack context, and `helm_values`.

`endpoint` is the raw RDS hostname in both modes. There is no `dns_name`: the
RDS certificate covers `*.{region}.rds.amazonaws.com`.

```bash
terraform output -json helm_values | jq
```

No password is ever an output.

## Shared mode

`mode = "shared"` creates nothing and plans to zero resources. The module
resolves `shared-{env}-postgres` with `data "aws_db_instance"` and
`shared-{env}-postgres/password` with `data "aws_secretsmanager_secret"`.
`security_group_id` comes back `null`.

Think twice before using it here. The shared tier means every product on it
shares one instance, and this one carries the identity data of all of them —
a noisy-neighbour incident on the shared instance becomes an
authentication outage across every Lerian product in that environment.

Every sizing variable in the tfvars is ignored in that mode.
