# products/notifications/postgres

Primary datastore for the notifications service. Root stack over
[`_modules/postgres-rds`](../../../_modules/postgres-rds).

One root, one datastore, one state file. See [`../README.md`](../README.md) for
the product-level picture: the chart's ConfigMap/Secret split, the deploy order
and the full Helm mapping.

| | |
|---|---|
| Module | `../../../_modules/postgres-rds` |
| State key | `aws/products/notifications/postgres/terraform.tfstate` |
| Creates | `notifications-{env}-postgres` (RDS instance) |
| Secret | `notifications-{env}-postgres/password` |
| Chart target | `.Values.config` (`POSTGRES_*`) and `.Values.secrets` (`POSTGRES_REPLICA_*`) |

## Run it

```bash
cd examples/aws/products/notifications/postgres

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/notifications/postgres/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

`../../../` is **three** levels up and lands on `examples/aws`, where both
`backend/` and `_modules/` live.

Prerequisites: `infra-base/vpc`. `infra-base/eks` is optional at apply time.

## One logical database, and Terraform knows its name

`POSTGRES_NAME` is emitted, which is a real difference from
[`products/midaz/postgres`](../../midaz/postgres). midaz runs two logical
databases (`onboarding`, `transaction`) on one instance; RDS creates exactly one
at provisioning time and the second comes from the application migration, so
Terraform there cannot know both and emits neither.

notifications runs one. RDS creates it, the chart's `POSTGRES_NAME` default is
the same string, and `database_name` here is the single source of truth for it.

The `golang-migrate` Job then applies DDL **inside** that database as a Helm
`pre-install`/`pre-upgrade` hook. Terraform creates the database; the Job creates
the tables.

## The read replica is emitted only when it exists

The chart ships every `POSTGRES_REPLICA_*` key as an empty string and treats
empty as "no replica, use the primary pool". So this root does **not** copy the
midaz trick of coalescing the replica host back to the primary — that would put
the read pool on the writer while telling the operator a replica is configured.

- `create_read_replica = false` → `helm_secret_values` is `{}`
- `create_read_replica = true` → the four address keys appear

Note where they go: `.Values.secrets`, not `.Values.config`. Nothing in that map
is a credential — they are a host, a port, a user and a database name — but the
chart declares them under `secrets`, so that is where they have to be written.
`POSTGRES_REPLICA_PASSWORD` is the sensitive one and comes from `secret_name`
through External Secrets; a read replica shares the master credentials of its
source instance, so it is the same secret.

## `DATABASE_URL` is deliberately absent

The migrations Job consumes a pre-built, URL-escaped DSN. It embeds the
password, so Terraform must not build it — the value would land in the state
file and in `terraform output` in cleartext.

Assemble it in the secret store (or through the ArgoCD Vault Plugin) from
`secret_name` plus the four values this root publishes:

```
postgres://USER:URLENCODED_PW@HOST:PORT/DB?sslmode=require
```

The chart's own comment in `templates/migrations-job.yaml` explains why it is
pre-built rather than assembled at runtime: the distroless Job image has no
shell to URL-encode the password with.

## No subchart to switch off

`notifications/Chart.yaml` declares no dependencies at all — no bundled Bitnami
PostgreSQL, and therefore no `postgresql.enabled: false` to remember. The chart
was written external-first. This is the one place where notifications is
*simpler* than midaz and the two `plugin-br-*` charts.

## `POSTGRES_SSLMODE` is not emitted

It is a client policy decision, not an infrastructure fact, and the chart default
is already `require`, which every RDS instance accepts. Do not copy the midaz
value here: that chart defaults to `disable`.

## Sizing

| Env | Class | Notes |
|---|---|---|
| dev | `db.t4g.micro` | ~USD 15/month. Performance Insights MUST stay false — AWS does not offer it below `db.t4g.medium`, and the module rejects the combination at plan time |
| stg | `db.t4g.medium` | first class above the PI exclusion list, so query-level observability matches prd |
| prd | `db.m7g.large`, Multi-AZ | plus a read replica |

`engine_version` stays MAJOR-only (`"16"`). Pinning a full minor is a
maintenance trap — AWS retired 16.3 and every apply that pinned it started
failing with `Cannot find version 16.3 for postgres`.

## Outputs

The seven uniform contract names (`mode`, `endpoint`, `port`,
`security_group_id`, `secret_arn`, `secret_name`, `identifier`), plus
`database_name`, `username`, `replica_endpoint`, `replica_identifier`,
`subnet_group_name`, the four cross-stack context outputs, and the two Helm maps
— `helm_values` for `.Values.config` and `helm_secret_values` for
`.Values.secrets`.
