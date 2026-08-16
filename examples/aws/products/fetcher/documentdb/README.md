# products/fetcher/documentdb

The DocumentDB cluster of the **fetcher** product. One root stack, one state file.

| | |
| --- | --- |
| Module | [`_modules/mongodb-documentdb`](../../../_modules/mongodb-documentdb) |
| Resource (dedicated) | `fetcher-{env}-docdb` |
| Resource (shared) | `shared-{env}-docdb` |
| Secret | `fetcher-{env}-docdb/password` |
| State key | `aws/products/fetcher/documentdb/terraform.tfstate` |
| Chart | `fetcher-helm 3.1.0 (appVersion 3.0.2)` |

## Running it

```bash
cd examples/aws/products/fetcher/documentdb

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/fetcher/documentdb/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

`../../../` is **three** levels up, not four: this directory is
`examples/aws/products/fetcher/documentdb`, so it lands on `examples/aws`, where
both `backend/` and `_modules/` live. `*.tfvars` is gitignored; `*.tfvars-example`
is not.

## Dedicated or shared

| `mode` | What happens | Resources |
| --- | --- | --- |
| `dedicated` (default) | Creates `fetcher-{env}-docdb`, its security group and its secret. | all |
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
| derived from `documentdb_tls` | `MONGO_PARAMETERS` | `common.configmap` |
| `master_username` | `MONGO_USER` | **`secrets`** |
| `secret_name` → External Secrets | `MONGO_PASSWORD` | `secrets` |

Not emitted: `MONGO_NAME` (chart default `fetcher-db`), `MONGO_TLS_CA_CERT`,
`MONGO_MAX_POOL_SIZE`.

## Gotchas

- **`MONGO_USER` lives under `secrets:`, not in the ConfigMap** — the opposite
  of reporter, which keeps it in `common.configmap`. Merging it into the
  ConfigMap here leaves the Secret key at its `fetcher` default and the
  application authenticates as the wrong role.
- `common.configmap` is rendered into a separate `<release>-common` ConfigMap
  (`templates/common/configmap.yaml`) that both the manager and the worker mount
  with `envFrom`. Per-component keys live in `manager.configmap` /
  `worker.configmap` and are **not** merged into it.
- **`retryWrites=false` is mandatory.** DocumentDB does not implement retryable
  writes; drivers enable them by default.
- **The fetcher chart already ships `mongodb.enabled: false`.** Unlike reporter,
  nothing has to be turned off — this chart expects an external cluster by
  default.

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
