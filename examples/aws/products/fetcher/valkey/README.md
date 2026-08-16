# products/fetcher/valkey

The ElastiCache Valkey replication group of the **fetcher** product. One root stack, one state file.

| | |
| --- | --- |
| Module | [`_modules/valkey-elasticache`](../../../_modules/valkey-elasticache) |
| Resource (dedicated) | `fetcher-{env}-valkey` |
| Resource (shared) | `shared-{env}-valkey` |
| Secret | `fetcher-{env}-valkey/auth-token` |
| State key | `aws/products/fetcher/valkey/terraform.tfstate` |
| Chart | `fetcher-helm 3.1.0 (appVersion 3.0.2)` |

## Running it

```bash
cd examples/aws/products/fetcher/valkey

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/fetcher/valkey/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

`../../../` is **three** levels up, not four: this directory is
`examples/aws/products/fetcher/valkey`, so it lands on `examples/aws`, where
both `backend/` and `_modules/` live. `*.tfvars` is gitignored; `*.tfvars-example`
is not.

## Dedicated or shared

| `mode` | What happens | Resources |
| --- | --- | --- |
| `dedicated` (default) | Creates `fetcher-{env}-valkey`, its security group and its secret. | all |
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
| `endpoint` (bare host) | `REDIS_HOST` | `common.configmap` |
| `port` | **`REDIS_PORT`** | `common.configmap` |
| `redis_db_index` | `REDIS_DB` | `common.configmap` |
| `secret_name` → External Secrets | `REDIS_PASSWORD` | `secrets` |

Not emitted: `REDIS_TLS` (**does not exist in this chart**), `REDIS_USER` (an
ElastiCache RBAC user this module does not create).

## Gotchas

- **`REDIS_HOST` is a bare host here and `REDIS_PORT` exists.**

  | | `REDIS_HOST` | `REDIS_PORT` |
  | --- | --- | --- |
  | midaz | `host:port` | does not exist |
  | reporter | `host:port` | does not exist |
  | **fetcher** | `host` | `6379` |

  The two near-twin products disagree. `values.yaml` ships `REDIS_HOST: "valkey"`
  and `REDIS_PORT: "6379"` as separate keys, so the combined form would be
  parsed as a hostname containing a colon.
- **`REDIS_TLS` does not exist in this chart, in any form.** That is why
  `transit_encryption_mode` stays `"preferred"` even in prd: the application
  cannot be told to speak TLS, so `"required"` would refuse every connection it
  makes. **CONFIRMAR before hardening.**
- **`REDIS_PASSWORD` *does* exist** (unlike reporter), so
  `auth_token_enabled = true` is reachable once the ExternalSecret is wired. It
  is left `false` so the first production apply is not the one that discovers
  the ExternalSecret is missing.
- The fetcher chart already ships `valkey.enabled: false`.

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
