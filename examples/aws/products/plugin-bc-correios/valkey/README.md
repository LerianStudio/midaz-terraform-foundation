# products/plugin-bc-correios/valkey

The ElastiCache Valkey replication group of the **plugin-bc-correios** product. One root stack, one state file.

| | |
| --- | --- |
| Module | [`_modules/valkey-elasticache`](../../../_modules/valkey-elasticache) |
| Resource (dedicated) | `plugin-bc-correios-{env}-valkey` |
| Resource (shared) | `shared-{env}-valkey` |
| Secret | `plugin-bc-correios-{env}-valkey/auth-token` |
| State key | `aws/products/plugin-bc-correios/valkey/terraform.tfstate` |
| Chart | `plugin-bc-correios-helm 2.2.0 (appVersion 1.2.0)` |

## Running it

```bash
cd examples/aws/products/plugin-bc-correios/valkey

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/plugin-bc-correios/valkey/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

`../../../` is **three** levels up, not four: this directory is
`examples/aws/products/plugin-bc-correios/valkey`, so it lands on `examples/aws`, where
both `backend/` and `_modules/` live. `*.tfvars` is gitignored; `*.tfvars-example`
is not.

## Dedicated or shared

| `mode` | What happens | Resources |
| --- | --- | --- |
| `dedicated` (default) | Creates `plugin-bc-correios-{env}-valkey`, its security group and its secret. | all |
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
| `"${endpoint}:${port}"` | `CACHE_ADDR` | `bc-correios.configmap` |
| `secret_name` → External Secrets | `CACHE_PASSWORD` | `bc-correios.secrets` |

Not emitted: `CACHE_TTL_SEC` (application cache lifetime; ElastiCache enforces no
TTL of its own).

## Gotchas

- **The cache variables are not called `REDIS_*`.** This chart uses
  `CACHE_ADDR`, `CACHE_TTL_SEC` and `CACHE_PASSWORD`. There is no `REDIS_HOST`,
  no `REDIS_PORT` and no `REDIS_DB` anywhere in it, so none of the midaz,
  reporter or fetcher mappings apply.
- **`CACHE_ADDR` must be `host:port` in one string.** The init container splits
  it back apart with `cut -d: -f1` / `cut -d: -f2`, so a bare hostname yields an
  empty port and the dependency wait hangs for its full five-minute timeout
  before the pod ever starts.
- **Setting it is not optional.** `templates/configmap.yaml` renders
  `CACHE_ADDR | default (printf "%s-primary:6379" ...)`, so leaving it empty does
  not mean "unset" — it means the in-cluster Valkey subchart service.
- **There is no cache TLS key of any kind**, which is why
  `transit_encryption_mode` stays `"preferred"` in every environment.
  `CACHE_PASSWORD` *does* exist, so `auth_token_enabled = true` is reachable once
  the ExternalSecret is wired.
- Set `valkey.enabled: false` **and** `valkey.external: true`.

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
