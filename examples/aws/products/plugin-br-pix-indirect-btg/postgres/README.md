# products/plugin-br-pix-indirect-btg/postgres

Pix message state for the four data-plane components. Root stack over
[`_modules/postgres-rds`](../../../_modules/postgres-rds).

One root, one datastore, one state file. See [`../README.md`](../README.md) for
the product-level picture: the five-component layout, the chart's internal
disagreements, and the full Helm mapping.

| | |
|---|---|
| Module | `../../../_modules/postgres-rds` |
| State key | `aws/products/plugin-br-pix-indirect-btg/postgres/terraform.tfstate` |
| Creates | `plugin-br-pix-indirect-btg-{env}-postgres` (RDS instance) |
| Secret | `plugin-br-pix-indirect-btg-{env}-postgres/password` |
| Chart target | `pix.configmap`, `inbound.configmap`, `outbound.configmap`, `reconciliation.configmap` |

## Run it

```bash
cd examples/aws/products/plugin-br-pix-indirect-btg/postgres

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/plugin-br-pix-indirect-btg/postgres/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

## `helm_values` is keyed by component

The chart gives every component its own ConfigMap. There is nothing to merge a
flat map into, so:

```bash
terraform output -json helm_values
# { "pix": {...}, "inbound": {...}, "outbound": {...}, "reconciliation": {...} }
```

All four entries are identical for this datastore — the differences between
components show up in the Valkey and DocumentDB roots, not here. `schedule` is
absent because `templates/schedule/configmap.yaml` carries no datastore key of
any kind.

## `DB_*`, not `POSTGRES_*`

| Chart | Prefix |
|---|---|
| plugin-br-pix-indirect-btg | `DB_HOST` / `DB_PORT` / `DB_USER` / `DB_NAME` |
| plugin-br-bank-transfer | `POSTGRES_HOST` / `POSTGRES_PORT` / `POSTGRES_USER` / `POSTGRES_DB` |
| notifications | `POSTGRES_HOST` / `POSTGRES_PORT` / `POSTGRES_USER` / `POSTGRES_NAME` |
| midaz | `DB_ONBOARDING_*` / `DB_TRANSACTION_*` |

## The chart will not render without this output

`_helpers.tpl` carries `plugin-br-pix-indirect-btg.dbHostRequired`, which
`fail()`s per component:

```
ERROR: <component>.configmap.DB_HOST is REQUIRED when the bundled postgresql
subchart is disabled or external.
  The in-cluster Service name is not derived on the external path.
```

The sibling helper `dbPasswordRequired` does the same for
`<component>.secrets.DB_PASSWORD`. Both have to be wired before the first
release — the second from `secret_name` through External Secrets.

## `DB_NAME`: the chart disagrees with itself, and this root picks

| Where | Default |
|---|---|
| `pix`, `inbound`, `outbound` | `pix` |
| `reconciliation` | `pix_btg` |
| bundled `postgresql` subchart | database `pix_btg`, user `pix_btg` |

RDS creates exactly **one** initial database. `helm_values` points all four
components at `database_name` (default `pix`) so that reconciliation does not
dial a database that was never created. Reported as a chart finding in the
product README — it needs a decision from the plugin team, and until it comes,
one consistent value is strictly better than the chart's three.

`DB_USER` has the same problem in miniature: the components default to `plugin`,
the bundled subchart provisions `pix_btg`. This root follows the application
side, which is the half that has to match at runtime, and emits `DB_USER`
explicitly anyway.

## The replica keys are always emitted

`DB_REPLICA_HOST` defaults to the **same host helper as `DB_HOST`** on all four
components — the chart expresses "no replica" by pointing the read pool at the
writer, not by leaving the keys unset. So this root always emits the four
`DB_REPLICA_*` keys and simply points them at the replica when one exists. Same
as midaz.

That is the opposite of `plugin-br-bank-transfer`, whose chart gates its whole
replica block on the host being present. Two plugins, two conventions.

It also matters on the external path: the chart's `postgresHost` helper returns
**empty** when the bundled subchart is disabled, and only `DB_HOST` has a
`required()` guard — an unset `DB_REPLICA_HOST` would silently render as `""`
and the read pool would fail at connect time with an unhelpful error.

## `DB_SSL_MODE` is not emitted

Client policy, not an infrastructure fact. The chart default is `disable`, which
RDS accepts; tighten it in the chart when the plugin is ready to validate
certificates.

`REPLICATION_PASSWORD` (in `pix/secrets.yaml`) is also not emitted: it is the
bundled subchart's streaming-replication credential, and an RDS read replica does
not use one.

## Sizing

| Env | Class | Notes |
|---|---|---|
| dev | `db.t4g.micro` | ~USD 15/month. Performance Insights MUST stay false |
| stg | `db.t4g.medium` | first class above the PI exclusion list |
| prd | `db.m7g.large`, Multi-AZ | plus a read replica |

`engine_version` stays MAJOR-only (`"16"`). The bundled subchart pins image tag
`"latest"`, so there is no chart-side version to match against.

## Outputs

The seven uniform contract names, plus `database_name`, `username`,
`replica_endpoint`, `replica_identifier`, `subnet_group_name`, the four
cross-stack context outputs, and `helm_values` (keyed by component).
