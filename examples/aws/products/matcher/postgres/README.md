# products/matcher/postgres

Primary datastore for the Matcher reconciliation service. Root stack over
[`_modules/postgres-rds`](../../../_modules/postgres-rds).

> **Composition inferred.** The Matcher chart is not in this repository — see the
> "Inferred composition" section of [`../README.md`](../README.md) before wiring
> anything. `helm_values` in this root is empty on purpose.

| | |
|---|---|
| Module | `../../../_modules/postgres-rds` |
| State key | `aws/products/matcher/postgres/terraform.tfstate` |
| Creates | `matcher-{env}-postgres` (RDS instance) |
| Secret | `matcher-{env}-postgres/password` |
| Chart target | **unknown** — no readable chart |

## Run it

```bash
cd examples/aws/products/matcher/postgres

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/matcher/postgres/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

## Why the dependency is believable

`charts/matcher/charts/postgresql-16.3.5.tgz` is Bitnami's PostgreSQL chart at
exactly the version midaz, plugin-br-bank-transfer and plugin-br-pix-indirect-btg
all pin. Its presence is solid evidence that the Matcher chart declares a
`postgresql` dependency. It says nothing about which env vars the application
reads.

## Wiring the release, for now

```bash
terraform output endpoint       # the host
terraform output port           # 5432
terraform output username       # the master user
terraform output database_name  # the initial database
terraform output secret_name    # -> External Secrets -> the password
```

For orientation only, **not** a recommendation to hardcode: the three readable
Lerian charts spell this datastore `POSTGRES_HOST` / `POSTGRES_PORT` /
`POSTGRES_USER` plus one of `POSTGRES_DB` or `POSTGRES_NAME`, or
`DB_HOST` / `DB_PORT` / `DB_USER` / `DB_NAME`. Matcher uses one of those, or
something else.

## `database_name` and `username` are choices, not chart defaults

- `database_name = "matcher"` — an initial database has to be called something.
  Naming it after the product claims nothing about application configuration, and
  the value is published as an output so the release can be pointed at it
  explicitly.
- `username = "postgres"` — the generic RDS default on purpose. An
  application-looking username with no chart behind it would be a guess dressed
  up as a contract.

## No read replica, even in prd

Every other product in this repository turns one on in production. This one does
not: there is no chart to confirm the Matcher application has a read path, and a
replica the application never queries is an idle instance on the bill.

`create_read_replica` is exposed and the plumbing is in place — turn it on once
the Matcher team confirms a read path exists.

## Sizing

| Env | Class | Notes |
|---|---|---|
| dev | `db.t4g.micro` | ~USD 15/month. Performance Insights MUST stay false — AWS does not offer it below `db.t4g.medium` and the module rejects the combination at plan time |
| stg | `db.t4g.medium` | first class above the PI exclusion list |
| prd | `db.m7g.large`, Multi-AZ | no replica, see above |

`engine_version` stays MAJOR-only (`"16"`). Pinning a full minor is a maintenance
trap — AWS retired 16.3 and every apply that pinned it started failing with
`Cannot find version 16.3 for postgres`.

## Outputs

The seven uniform contract names, plus `database_name`, `username`,
`replica_endpoint`, `replica_identifier`, `subnet_group_name`, the four
cross-stack context outputs, and `helm_values` — which is `{}` and explains
itself in the file.
