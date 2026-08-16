# products/br-consignado-gw/valkey

Cache for the consignado gateway API. Root stack over
[`_modules/valkey-elasticache`](../../../_modules/valkey-elasticache).

One root, one datastore, one state file. See [`../README.md`](../README.md) for
the product-level picture.

| | |
|---|---|
| Module | `../../../_modules/valkey-elasticache` |
| State key | `aws/products/br-consignado-gw/valkey/terraform.tfstate` |
| Creates | `br-consignado-gw-{env}-valkey` (ElastiCache replication group) |
| Secret | `br-consignado-gw-{env}-valkey/auth-token` |
| Chart target | `api.configmap` — **one key**, `REDIS_HOST` |

The `ui` component has no Redis variable.

## Run it

```bash
cd examples/aws/products/br-consignado-gw/valkey

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/br-consignado-gw/valkey/terraform.tfstate"

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
`check "eks_node_security_group_resolved"` lives in that module and warns while
the lookup is empty.

> `var.subnet_tag_type` (`"database"`) is the **placement** filter and goes to
> `valkey-elasticache` only. `product-network` keeps its own default
> (`"private"`), the **ingress** filter.

## One key, and the port goes inside it

`REDIS_HOST` is the **only** Redis variable this chart defines. A grep for
`REDIS` across the whole chart returns `values.yaml:61`,
`values-template.yaml:17` and documentation examples — nothing else. No
`REDIS_PORT`, no `REDIS_PASSWORD`, no `REDIS_TLS`, no `REDIS_DB`, no
`REDIS_USER`, no `MULTI_TENANT_REDIS_*`.

So the port lives inside the host, as the chart's own upgrade guide shows
verbatim (`docs/UPGRADE-1.0.md:138`):

```yaml
REDIS_HOST: "redis.cache.svc.cluster.local:6379"
```

`helm_values` emits `"${endpoint}:${port}"`. A bare hostname produces a client
dialling port zero.

Same shape as the midaz chart, and the **opposite** of
`plugin-access-manager`, whose template appends the port itself so a `host:port`
value renders as `host:port:port`. Read the template before copying a
`helm_values` block between products.

## No subcharts — nothing to turn off

`Chart.yaml` has **no `dependencies:` block**, stated as deliberate at
`README.md:13`. There is no `valkey.enabled: false` to set; the chart has always
expected an external cache.

`values.yaml:61` ships `REDIS_HOST: ""`, so an unwired release fails to connect
rather than quietly aiming at an in-cluster service — but the wiring is still
mandatory.

## The security gap here is the hardest in this batch

`auth_token_enabled = false` and `transit_encryption_mode = "preferred"` in all
three environments, **including production**, and unlike everywhere else this is
not a "the client has not been configured yet" problem. It is a missing
variable problem:

- **no `REDIS_PASSWORD`** → an enforced auth token has no way to reach the
  client. Enabling it locks the API out.
- **no `REDIS_TLS`** → there is no way to tell the client to negotiate TLS, so
  `"required"` locks it out too.

**Closing this gap needs a chart change first**, not a tfvars change — unlike
tracer, where both knobs already exist and it is a values change.

The token **is** generated and written to
`br-consignado-gw-{env}-valkey/auth-token` regardless, so the day the chart
grows the variables, enabling it is one tfvars line and no rebuild. Until then
the cache is protected by the security group and the private subnets alone.

## Availability

`multi_az_enabled` requires **both** `num_cache_clusters >= 2` **and**
`automatic_failover_enabled = true`. Setting one without the others fails the
apply, not the plan.

A single cache cluster (the dev sizing) means `reader_endpoint` comes back
empty. The chart has no reader variable anyway.

## Outputs

Seven uniform contract names — `mode`, `endpoint`, `port`, `security_group_id`,
`secret_arn`, `secret_name`, `identifier` — plus `reader_endpoint`,
`engine_version_actual`, `auth_token_enabled`, `transit_encryption_enabled`,
`subnet_group_name`, the cross-stack context, and `helm_values`.

`endpoint` and `port` are published separately as well as combined in
`helm_values`, because a raw endpoint is what any non-Helm consumer wants.

`endpoint` is the raw ElastiCache primary endpoint in both modes. There is no
`dns_name`: with transit encryption on, the certificate only covers
`*.{cluster}.{region}.cache.amazonaws.com`, so an alias in front of the primary
endpoint fails TLS hostname verification.

```bash
terraform output -json helm_values | jq
```

## Shared mode

`mode = "shared"` creates nothing and plans to zero resources. The module
resolves `shared-{env}-valkey` with
`data "aws_elasticache_replication_group"` and the secret
`shared-{env}-valkey/auth-token` with `data "aws_secretsmanager_secret"`, so
`endpoint`, `reader_endpoint` and `port` come from the resolved group.
`security_group_id` comes back `null`.

The name is fully derived, so this root exposes no variable for it. The module's
own `shared_identifier` is the escape hatch.
