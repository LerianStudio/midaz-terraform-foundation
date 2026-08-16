# products/reporter/documentdb

The DocumentDB cluster of the **reporter** product. One root stack, one state file.

| | |
| --- | --- |
| Module | [`_modules/mongodb-documentdb`](../../../_modules/mongodb-documentdb) |
| Resource (dedicated) | `reporter-{env}-docdb` |
| Resource (shared) | `shared-{env}-docdb` |
| Secret | `reporter-{env}-docdb/password` |
| State key | `aws/products/reporter/documentdb/terraform.tfstate` |
| Chart | `reporter-helm 3.2.0 (appVersion 2.3.0)` |

## Running it

```bash
cd examples/aws/products/reporter/documentdb

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/reporter/documentdb/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

`../../../` is **three** levels up, not four: this directory is
`examples/aws/products/reporter/documentdb`, so it lands on `examples/aws`, where
both `backend/` and `_modules/` live. `*.tfvars` is gitignored; `*.tfvars-example`
is not.

## Dedicated or shared

| `mode` | What happens | Resources |
| --- | --- | --- |
| `dedicated` (default) | Creates `reporter-{env}-docdb`, its security group and its secret. | all |
| `shared` | Creates nothing. Resolves `shared-{env}-docdb` and its secret by name, through a data source. | none |

In `shared` mode `security_group_id` comes back `null`: opening the shared
documentdb is the job of `products/shared-resources/documentdb`, not of this stack.

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
| literal `"mongodb"` | `MONGO_URI` | `common.configmap` |
| `endpoint` | `MONGO_HOST` | `common.configmap` |
| `port` | `MONGO_PORT` | `common.configmap` |
| `master_username` | `MONGO_USER` | `common.configmap` |
| derived from `documentdb_tls` | `MONGO_PARAMETERS` | `common.configmap` |
| `secret_name` → External Secrets | `MONGO_PASSWORD` | `secrets` |

`MONGO_URI` is a **scheme**, not a connection string. `mongodb` is the only
correct value: DocumentDB publishes no SRV records, so `mongodb+srv` cannot
resolve.

Not emitted: `MONGO_NAME` (chart default `reporter-db`; DocumentDB creates a
database lazily on first write, so Terraform does not know it),
`MONGO_TLS_CA_CERT` (the global RDS CA bundle, not distributed by Terraform),
`MONGO_MAX_POOL_SIZE` (application tuning).

## Gotchas

- **One unsuffixed `MONGO_*` set.** midaz carries three sets
  (`MONGO_ONBOARDING_*`, `MONGO_TRANSACTION_*`, `MONGO_*`); reporter has one,
  shared by the manager and the worker. None of the midaz mapping transfers.
- **`retryWrites=false` is mandatory** and is why `MONGO_PARAMETERS` is emitted
  at all. DocumentDB does not implement retryable writes and every driver
  enables them by default, so omitting it makes every write fail.
- **The reporter chart ships `mongodb.enabled: true`** — unlike fetcher, whose
  subcharts are all off. Set `mongodb.enabled: false` **and**
  `mongodb.external: true`, or an in-cluster MongoDB is deployed next to
  DocumentDB and the password resolution stays pointed at the subchart Secret.
- `MONGO_PASSWORD` is normally single-sourced from the bundled Bitnami Secret.
  With the subchart off that path is gone and the ExternalSecret has to fill it.

## Cost

`db.t3.medium`, one instance, roughly **USD 60/month** in dev. There is no cheaper
class: the RDS burstable micro/small range does not exist for DocumentDB, and the
module rejects those values with a plan-time precondition. If a dev environment
cannot carry it, set `mode = "shared"`.

## Validation

```bash
terraform fmt -check -recursive .
terraform init -backend=false -input=false
terraform validate
tflint --config=../../../../../.tflint.hcl
trivy config . --severity HIGH,CRITICAL --tf-exclude-downloaded-modules --quiet
```
