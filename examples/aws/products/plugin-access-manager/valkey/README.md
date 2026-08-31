# products/plugin-access-manager/valkey

Session and token cache for the access manager. Root stack over
[`_modules/valkey-elasticache`](../../../_modules/valkey-elasticache).

One root, one datastore, one state file. See [`../README.md`](../README.md) for
the product-level picture.

| | |
|---|---|
| Module | `../../../_modules/valkey-elasticache` |
| State key | `aws/products/plugin-access-manager/valkey/terraform.tfstate` |
| Creates | `plugin-access-manager-{env}-valkey` (ElastiCache replication group) |
| Secret | `plugin-access-manager-{env}-valkey/auth-token` |
| Chart target | `identity.configmap` **and** `auth.configmap` (`REDIS_HOST`, `REDIS_PORT`, `REDIS_TLS`) |

## Two components read this cache

`identity` and `auth` carry **independent** ConfigMaps with **identically
named** `REDIS_*` keys (`templates/identity/configmap.yaml:54-67`,
`templates/auth/configmap.yaml:24-37`). Merge `helm_values` into **both**.
Setting one leaves the other pointed at the in-cluster default
`plugin-access-manager-valkey-primary`.

`auth-backend` (Casdoor) has no Redis variables at all.

## Run it

```bash
cd examples/aws/products/plugin-access-manager/valkey

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/plugin-access-manager/valkey/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

`../../../` is **three** levels up and lands on `examples/aws`. Verified with
`terraform init -backend=false`.

Prerequisites: `infra-base/vpc`. `infra-base/eks` is optional at apply time.

## Ingress

Resolved by [`_modules/product-network`](../../../_modules/product-network) as
`module.network`, `enabled = var.mode == "dedicated"`: `Type=private` subnet
CIDRs plus the EKS node security group matched by
`tag:Name = "lerian-{env}-eks-node"` with the plural data source.
`check "eks_node_security_group_resolved"` lives in that module.

> `var.subnet_tag_type` (`"database"`) is the **placement** filter and goes to
> `valkey-elasticache` only. `product-network` keeps its own default
> (`"private"`), the **ingress** filter.

## ⚠ `REDIS_HOST` must be BARE — the chart appends the port itself

The most dangerous line in this product's wiring, and the **exact opposite** of
the midaz rule.

Both ConfigMap templates render the key as:

```
printf "%s:%s" <REDIS_HOST value> <REDIS_PORT value>
```

`templates/auth/configmap.yaml:24`, `templates/identity/configmap.yaml:54`.

So the values key is a **hostname** and the *rendered env var* is `host:port`.
Passing `"my-cache:6379"` into values produces `"my-cache:6379:6379"` in the
ConfigMap — a client that can resolve nothing.

Four Lerian charts, four behaviours behind one variable name:

| Chart | what the values key takes |
|---|---|
| midaz | `"host:port"` — `REDIS_PORT` was deleted in chart 3.0 |
| br-consignado-gw | `"host:port"` — the only Redis key the chart has |
| **plugin-access-manager** | **bare host** — the template appends `REDIS_PORT` |
| tracer | bare host, but the key is `MULTI_TENANT_REDIS_HOST` |

`helm_values` here emits `REDIS_HOST` bare and `REDIS_PORT` separately, which is
what this chart wants. Read the template before copying a `helm_values` block
between products.

## Turning the bundled subchart off

```yaml
valkey:
  enabled: false     # values.yaml:445
```

This dependency is **not** aliased (unlike the PostgreSQL one — see the sibling
root), so the values key really is `valkey`. There is no `valkey.external` key.

## `REDIS_USER` blocks auth-token enforcement

`auth_token_enabled` is `false` in every environment, including production, and
here the reason is **not** the usual "the chart has no password field" — it has
one (`REDIS_PASSWORD`, `values.yaml:307`).

The blocker is `REDIS_USER`. The chart sends a Redis **username**: default
`"auth"` on the auth component (`values.yaml:294`), `"identity"` on identity.
ElastiCache auth tokens are the **legacy password-only AUTH**, which has no
username at all — a client that sends `AUTH <user> <token>` against a
token-protected replication group is **rejected**.

Making this work requires **ElastiCache RBAC users**, which
`_modules/valkey-elasticache` does not create.

That is also why `REDIS_USER` is **not** emitted by `helm_values` and is marked
`# CONFIRMAR no chart` in `outputs.tf`: Terraform cannot produce a correct value
in either state. With the token off there is no user to name; with it on the
correct answer is an RBAC user that does not exist. The operator decides.

Until then the cache is protected by the security group and the private subnets
alone. The token **is** generated and stored at
`plugin-access-manager-{env}-valkey/auth-token` regardless.

## `REDIS_TLS` reports *required*, not *available*

`transit_encryption_enabled` is `true` everywhere, but
`transit_encryption_mode` is `"preferred"` — ElastiCache accepts TLS and
plaintext alike. `helm_values` only reports `"true"` when the mode is
`"required"`.

The chart does have a `REDIS_TLS` key for this value to land in, so the mode is
the only lever. It stays `"preferred"` because the chart also has
`REDIS_CA_CERT` and nothing in this repository distributes the ElastiCache CA
bundle into the pods.

## Keys deliberately left alone

| Key | Why |
|---|---|
| `REDIS_MASTER_NAME` | a Redis **Sentinel** master name. ElastiCache replication groups are not Sentinel; the primary endpoint is already the failover-aware address, and there is no Sentinel service to name. |
| `REDIS_CA_CERT` | the ElastiCache CA bundle; Terraform does not distribute it. |
| `REDIS_DB`, `REDIS_PROTOCOL`, `REDIS_SCAN_COUNT`, `REDIS_TOKEN_LIFETIME`, `REDIS_TOKEN_REFRESH_DURATION` | application tuning. Every Valkey node exposes 16 logical databases and Terraform creates none of them; the rest describe token behaviour. |
| `REDIS_USE_GCP_IAM`, `REDIS_SERVICE_ACCOUNT`, `GOOGLE_APPLICATION_CREDENTIALS` | a Google Memorystore IAM path. Not applicable on AWS. |

## Availability

`multi_az_enabled` requires **both** `num_cache_clusters >= 2` **and**
`automatic_failover_enabled = true`. Setting one without the others fails the
apply, not the plan. A single cache cluster (the dev sizing) means
`reader_endpoint` comes back empty; neither component has a reader variable
anyway.

## Naming headroom

`plugin-access-manager-prd-valkey` is **32** characters against the ElastiCache
`replication_group_id` limit of **40** — the longest derived name in this batch.
The module asserts it at plan time
(`_modules/valkey-elasticache/main.tf:180`), so a future rename that overruns
fails the plan with a message naming the string, rather than the apply.

## Outputs

Seven uniform contract names — `mode`, `endpoint`, `port`, `security_group_id`,
`secret_arn`, `secret_name`, `identifier` — plus `reader_endpoint`,
`engine_version_actual`, `auth_token_enabled`, `transit_encryption_enabled`,
`subnet_group_name`, the cross-stack context, and `helm_values`.

`endpoint` is the raw ElastiCache primary endpoint in both modes, and it is
`REDIS_HOST` verbatim. There is no `dns_name`: with transit encryption on, the
certificate only covers `*.{cluster}.{region}.cache.amazonaws.com`.

```bash
terraform output -json helm_values | jq
```

`REDIS_PASSWORD` is never an output.

## Shared mode

`mode = "shared"` creates nothing and plans to zero resources. The module
resolves `shared-{env}-valkey` with
`data "aws_elasticache_replication_group"` and the secret
`shared-{env}-valkey/auth-token` with `data "aws_secretsmanager_secret"`.
`security_group_id` comes back `null`.

The name is fully derived, so this root exposes no variable for it. The module's
own `shared_identifier` is the escape hatch.
