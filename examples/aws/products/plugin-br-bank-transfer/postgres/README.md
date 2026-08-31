# products/plugin-br-bank-transfer/postgres

TED origination state, the idempotency ledger and the outbox. Root stack over
[`_modules/postgres-rds`](../../../_modules/postgres-rds).

One root, one datastore, one state file. See [`../README.md`](../README.md) for
the product-level picture: the single-tenant / multi-tenant split, the subchart
switches, and the full Helm mapping.

| | |
|---|---|
| Module | `../../../_modules/postgres-rds` |
| State key | `aws/products/plugin-br-bank-transfer/postgres/terraform.tfstate` |
| Creates | `plugin-br-bank-transfer-{env}-postgres` (RDS instance) |
| Secret | `plugin-br-bank-transfer-{env}-postgres/password` |
| Chart target | `bankTransfer.configmap` (`POSTGRES_*`) |

## Run it

```bash
cd examples/aws/products/plugin-br-bank-transfer/postgres

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/plugin-br-bank-transfer/postgres/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

`../../../` is **three** levels up and lands on `examples/aws`.

## `POSTGRES_DB`, not `POSTGRES_NAME`

Three Lerian charts, three spellings of the same idea:

| Chart | Key for the database name |
|---|---|
| plugin-br-bank-transfer | `POSTGRES_DB` |
| notifications | `POSTGRES_NAME` |
| midaz | `DB_ONBOARDING_NAME` / `DB_TRANSACTION_NAME` |

There is no shared convention to lean on. The value here is a fact rather than a
guess — the plugin runs one logical database, RDS creates it at provisioning
time, and the chart default (`bank_transfer`) is the same string as the bundled
subchart's `postgresql.auth.database`.

## Both subchart switches, not one

```yaml
postgresql:
  enabled:  false     # do not deploy the bundled Bitnami subchart
  external: true      # and do not read credentials from its Secret
```

`templates/deployment.yaml` picks the source of `POSTGRES_PASSWORD` from exactly
that pair: with `external` still false it keeps a `secretKeyRef` pointed at a
subchart Secret that no longer exists.

## The migration hook needs its own credential

`migrations.enabled` is true by default and the Job runs as a Helm
`pre-install`/`pre-upgrade` hook — before the application Secret exists. On the
external-PostgreSQL path the chart renders a separate, minimal
`<fullname>-migrations` Secret carrying only `POSTGRES_PASSWORD`, and
`bank-transfer.migrationPostgresPassword` calls `required()` on
`bankTransfer.secrets.POSTGRES_PASSWORD`. Leave it empty and the render fails
with that message.

Wire it from `secret_name` through External Secrets, same as the runtime
password.

## The read replica is emitted only when it exists

`templates/configmap.yaml` wraps the whole `POSTGRES_REPLICA_*` block in
`{{- if .Values.bankTransfer.configmap.POSTGRES_REPLICA_HOST }}`, so an unset
host means "no CQRS read pool". This root follows that:

- `create_read_replica = false` → `helm_values` has no replica keys
- `create_read_replica = true` → `POSTGRES_REPLICA_HOST` / `_PORT` / `_USER` /
  `_DB` appear

It deliberately does **not** copy the midaz behaviour of coalescing the replica
host back to the primary. midaz needs that because its chart defaults those
variables to a subchart Service that vanishes when the subchart is off; this
chart has no such trap, and pointing the read pool at the writer while reporting
a replica would be worse than leaving it unset.

`POSTGRES_REPLICA_PASSWORD` comes from the same `secret_name`: a read replica
shares the master credentials of its source instance.

## Single-tenant only

The entire `POSTGRES_*` block sits inside `{{- if not $multiTenantEnabled }}`.
With `MULTI_TENANT_ENABLED = "true"` the chart renders none of it and the plugin
resolves per-tenant databases through the tenant-manager. Merging `helm_values`
into a multi-tenant release is harmless but has no effect.

## `POSTGRES_SSLMODE` is not emitted

Client policy, not an infrastructure fact, and the chart default is already
`require` — which every RDS instance accepts.

## Sizing

| Env | Class | Notes |
|---|---|---|
| dev | `db.t4g.micro` | ~USD 15/month. Performance Insights MUST stay false |
| stg | `db.t4g.medium` | first class above the PI exclusion list |
| prd | `db.m7g.large`, Multi-AZ | plus the CQRS read replica |

`engine_version` stays MAJOR-only (`"16"`). The bundled subchart pins
`bitnami/postgresql:17.4.0`; nothing observed in the chart requires 17, but see
the "Findings for the chart owners" section of the product README.

## Outputs

The seven uniform contract names, plus `database_name`, `username`,
`replica_endpoint`, `replica_identifier`, `subnet_group_name`, the four
cross-stack context outputs, and `helm_values`.
