# products/reporter/valkey

The ElastiCache Valkey replication group of the **reporter** product. One root stack, one state file.

| | |
| --- | --- |
| Module | [`_modules/valkey-elasticache`](../../../_modules/valkey-elasticache) |
| Resource (dedicated) | `reporter-{env}-valkey` |
| Resource (shared) | `shared-{env}-valkey` |
| Secret | `reporter-{env}-valkey/auth-token` |
| State key | `aws/products/reporter/valkey/terraform.tfstate` |
| Chart | `reporter-helm 3.2.0 (appVersion 2.3.0)` |

## Running it

```bash
cd examples/aws/products/reporter/valkey

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/reporter/valkey/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

`../../../` is **three** levels up, not four: this directory is
`examples/aws/products/reporter/valkey`, so it lands on `examples/aws`, where
both `backend/` and `_modules/` live. `*.tfvars` is gitignored; `*.tfvars-example`
is not.

## Dedicated or shared

| `mode` | What happens | Resources |
| --- | --- | --- |
| `dedicated` (default) | Creates `reporter-{env}-valkey`, its security group and its secret. | all |
| `shared` | Creates nothing. Resolves `shared-{env}-valkey` and its secret by name, through a data source. | none |

In `shared` mode `security_group_id` comes back `null`: opening the shared
valkey is the job of `products/shared-resources/valkey`, not of this stack.

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
| `"${endpoint}:${port}"` | `REDIS_HOST` | `common.configmap` |
| derived from `transit_encryption_mode` | `REDIS_TLS` | `common.configmap` |
| `redis_db_index` | `REDIS_DB` | `common.configmap` |

Not emitted: `REDIS_PASSWORD` (**does not exist** — see below), `REDIS_CA_CERT`,
`REDIS_PROTOCOL` (RESP version, a client choice), `REDIS_MASTER_NAME` (a Sentinel
name; ElastiCache is not Sentinel), `REDIS_SERVICE_ACCOUNT` /
`GOOGLE_APPLICATION_CREDENTIALS` (a GCP MemoryStore path with no AWS
equivalent).

## Gotchas

- **`REDIS_HOST` carries `host:port`.** There is no `REDIS_PORT` key anywhere in
  this chart. A bare hostname produces an application that dials port 0.
  fetcher — the near-twin product — splits the two. Read the chart, not the
  sibling.
- **`REDIS_PASSWORD` does not exist in this chart.** `values.yaml` says so
  explicitly: the key was omitted because the bundled valkey runs with
  `auth.enabled: false`. That is why `auth_token_enabled` stays `false` in every
  environment, including prd — the token *is* generated and stored, but
  enforcing it would lock the application out with no chart key to unlock it.
  **CONFIRMAR with the chart owners before hardening.**
- `REDIS_TLS` reports whether TLS is **required**, not whether it is available.
  `preferred` accepts TLS and plaintext alike and the chart connects in
  plaintext, so only `required` reports `"true"`.
- The reporter chart ships `valkey.enabled: true`. Set it to `false`. There is no
  `valkey.external` key in this chart — `enabled: false` is the whole switch.

## Cost

`cache.t4g.micro`, one cache cluster, roughly **USD 12/month** in dev. This is the
cheapest of the four datastores by an order of magnitude.

## Validation

```bash
terraform fmt -check -recursive .
terraform init -backend=false -input=false
terraform validate
tflint --config=../../../../../.tflint.hcl
trivy config . --severity HIGH,CRITICAL --tf-exclude-downloaded-modules --quiet
```
