# products/plugin-bc-correios/postgres

The RDS PostgreSQL instance of the **plugin-bc-correios** product. One root stack, one state file.

| | |
| --- | --- |
| Module | [`_modules/postgres-rds`](../../../_modules/postgres-rds) |
| Resource (dedicated) | `plugin-bc-correios-{env}-postgres` |
| Resource (shared) | `shared-{env}-postgres` |
| Secret | `plugin-bc-correios-{env}-postgres/password` |
| State key | `aws/products/plugin-bc-correios/postgres/terraform.tfstate` |
| Chart | `plugin-bc-correios-helm 2.2.0 (appVersion 1.2.0)` |

## Running it

```bash
cd examples/aws/products/plugin-bc-correios/postgres

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/plugin-bc-correios/postgres/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

`../../../` is **three** levels up, not four: this directory is
`examples/aws/products/plugin-bc-correios/postgres`, so it lands on `examples/aws`, where
both `backend/` and `_modules/` live. `*.tfvars` is gitignored; `*.tfvars-example`
is not.

## Dedicated or shared

| `mode` | What happens | Resources |
| --- | --- | --- |
| `dedicated` (default) | Creates `plugin-bc-correios-{env}-postgres`, its security group and its secret. | all |
| `shared` | Creates nothing. Resolves `shared-{env}-postgres` and its secret by name, through a data source. | none |

In `shared` mode `security_group_id` comes back `null`: opening the shared
postgres is the job of `products/shared-resources/postgres`, not of this stack.

## Outputs

The seven uniform contract names — `mode`, `endpoint`, `port`,
`security_group_id`, `secret_arn`, `secret_name`, `identifier` — plus the
service-specific ones and `helm_values`. `endpoint` is the **raw AWS host** in
both modes: there is no private DNS zone in this repository, because every AWS
datastore presents a certificate for its own service domain and a CNAME in front
of it breaks TLS hostname verification.

## Helm handoff

```bash
terraform output -json helm_values | jq
```

| Terraform | Chart env var | Destination |
| --- | --- | --- |
| `endpoint` | `POSTGRES_HOST` | `bc-correios.configmap` |
| `port` | `POSTGRES_PORT` | `bc-correios.configmap` |
| `username` | `POSTGRES_USER` | `bc-correios.configmap` |
| `database_name` | `POSTGRES_NAME` | `bc-correios.configmap` |
| literal `"require"` | `POSTGRES_SSLMODE` | `bc-correios.configmap` |
| `secret_name` → External Secrets | `POSTGRES_PASSWORD` | `bc-correios.secrets` |

Not emitted: `POSTGRES_MAX_CONNS` / `POSTGRES_MIN_CONNS` (application pool
tuning).

## Gotchas

- **The variables are `POSTGRES_*`, not `DB_*`.** Nothing about the midaz
  PostgreSQL mapping (`DB_ONBOARDING_HOST`, `DB_TRANSACTION_HOST`, the
  `REPLICA_*` pairs) transfers to this chart.
- **Two chart defaults are illegal on RDS.** `POSTGRES_NAME` and `POSTGRES_USER`
  both default to `plugin-bc-correios`; RDS restricts `db_name` and the master
  username to letters, digits and underscores starting with a letter, and
  `CreateDBInstance` rejects the hyphens outright. This root defaults to
  `bc_correios` for both and validates them, and `helm_values` emits the values
  so the chart follows RDS. **Leaving the chart defaults in place points the
  application at a database that does not exist.**
- **`POSTGRES_SSLMODE = "require"` is emitted**, overriding the chart default
  `disable`. RDS presents a certificate on every instance, so `require` costs
  nothing. Not `verify-full`: that needs the global RDS CA bundle mounted in the
  pod, which Terraform does not distribute.
- **The bundled subchart is PostgreSQL 17.4; this root provisions 16.** 16 is the
  repository-wide default (midaz and the shared tier run it), not a verified
  requirement of this plugin. **CONFIRMAR** whether the application depends on
  anything that landed in 17; if so, move `engine_version`, `family` and
  `major_engine_version` together.
- Set `postgresql.enabled: false` **and** `postgresql.external: true` — the
  chart's `infraSecretRef` helper checks both before deciding whether to read the
  password from the subchart Secret or from the application Secret.
- The chart also ships `global.externalPostgresDefinitions`, a bootstrap Job that
  creates roles and grants against an external instance. It needs admin
  credentials; point it at `secret_name` rather than at a hand-typed password.

## Cost

`db.t4g.micro` with 20 GB, roughly **USD 15/month** in dev. Performance Insights must
stay off on that class — AWS does not offer it on t2/t3/t4g micro and small, and the
module rejects the combination at plan time.

## Validation

```bash
terraform fmt -check -recursive .
terraform init -backend=false -input=false
terraform validate
tflint --config=../../../../../.tflint.hcl
trivy config . --severity HIGH,CRITICAL --tf-exclude-downloaded-modules --quiet
```
