# products/br-sfn/valkey

Cache for the br-sfn SFN rails monorepo. Root stack over
[`_modules/valkey-elasticache`](../../../_modules/valkey-elasticache).

One root, one datastore, one state file. See [`../README.md`](../README.md) for
the product-level picture: deploy order, the shared-vs-dedicated model, and the
full Helm mapping.

| | |
|---|---|
| Module | `../../../_modules/valkey-elasticache` |
| State key | `aws/products/br-sfn/valkey/terraform.tfstate` |
| Creates | `br-sfn-{env}-valkey` (ElastiCache replication group) |
| Secret | `br-sfn-{env}-valkey/auth-token` |
| Chart target | `correios.configmap.CACHE_ADDR` — and only that |
| Chart verified | br-sfn 1.1.0, appVersion `1.0.0-beta.1` |

The CRM deployment has no Redis variables at all.

## Run it

```bash
cd examples/aws/products/br-sfn/valkey

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/br-sfn/valkey/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

`../../../` is **three** levels up and lands on `examples/aws`, where both
`backend/` and `_modules/` live. Verified with `terraform init`.

Prerequisites: `infra-base/vpc`. `infra-base/eks` is optional at apply time —
see *Ingress* below.

## What this root decides

The module already resolves the VPC and the subnets by itself. This root exists
for three things the module cannot do:

1. **Derive the cross-stack names.** `lerian-{env}-vpc` and `lerian-{env}-eks`.
   Note the `lerian` prefix on both: they belong to `infra-base`, not to br-sfn.
   That is also why this root does **not** call the `naming` module.
2. **Compute the ingress allow list.**
3. **Translate to the chart**, which for Valkey is more than a rename — see
   below.

It creates no AWS resource of its own.

## Ingress

Identical to the sibling roots, because it is literally the same code: resolved
by [`_modules/product-network`](../../../_modules/product-network), called here
as `module.network` with `enabled = var.mode == "dedicated"`. `Type=private`
subnet CIDRs plus the EKS node security group, matched by
`tag:Name = "lerian-{env}-eks-node"`; `check "eks_node_security_group_resolved"`
lives in that module and warns while the lookup is empty. See its README for the
plural-data-source rule and the deploy-order window it covers.

> `var.subnet_tag_type` (`"database"`) selects the subnets the **replication
> group is placed in** and goes to `valkey-elasticache` only. `product-network`
> keeps its own default (`"private"`), the subnets whose CIDRs become
> **ingress**.

The "nothing can reach this cache at all" case is **not** re-asserted here: the
module already carries `check "ingress_is_reachable"` for it.

## The chart names exactly one cache variable, on exactly one rail

This is the whole non-secret surface:

```yaml
correios:
  configmap:
    CACHE_ADDR: "<host>:<port>"      # values-template.yaml:74
```

A grep for `CACHE_ADDR`, `REDIS_`, `VALKEY_` or `MULTI_TENANT` over the entire
chart — `values.yaml`, `values-template.yaml`, `values.schema.json` and every
template — returns that single line and nothing else.

`helm_values` therefore has **one key**, and it belongs to `correios.configmap`.
It carries `host:port` in one string, as the chart's own comment
(*"valkey/redis host:port"*) specifies; there is no `CACHE_HOST`/`CACHE_PORT`
pair to split it into.

**None of the midaz keys exist here**: no `REDIS_HOST`, no `REDIS_TLS`, no
`REDIS_DB`, no `MULTI_TENANT_*`, no `REDIS_PASSWORD`.

## What is unknown, and is not guessed

The chart README states that the four SPI components *"ride one Postgres, one
Redis and one RedPanda"* (`README.md:40-42`) — so SPI **does** use this cache.
But no SPI cache variable is named anywhere in the chart.

That is not an oversight in the chart. br-sfn has **no fixed env allowlist**:
`<component>.configmap` and `<component>.secrets` are emitted **verbatim** into
each component's ConfigMap and Secret (`README.md:66-72`), so new env vars never
need a chart change — and the names live in the br-sfn application repository
rather than in the chart.

> **CONFIRMAR no chart:** the cache env var name(s) read by `spi` (api, dict,
> brcode, core), and by `siloc` / `spb` / `scr` / `desk` if they use a cache at
> all. The chart cannot answer this; the br-sfn service owners can.

Until that is answered, use the `endpoint` and `port` outputs directly and name
the key in the component's own `configmap:` block.

**A guessed key would be worse than no key.** Because the chart passes component
configmaps through untouched, a wrong name lands in the ConfigMap with no error
and the rail falls back to whatever default it compiles in.

## No TLS switch and no password key

`transit_encryption_mode` stays `"preferred"` and `auth_token_enabled` stays
`false` in **every** environment, production included. That is a consequence of
the chart surface above, not an oversight:

- There is no TLS switch and no CA bundle key anywhere in the chart, so nothing
  can tell a rail to speak TLS. `"required"` would lock it out with nothing in
  the values to explain why.
- `correios.secrets` lists `POSTGRES_PASSWORD`, `ENCRYPTION_KEY` and
  `RABBITMQ_URL` (`values-template.yaml:77-80`) — **no cache password**. There is
  nowhere to put an ElastiCache AUTH token, and sending one over a plaintext
  connection would put the credential on the wire anyway.

The token **is** generated and written to `br-sfn-{env}-valkey/auth-token`
regardless, so enabling it later is a tfvars change plus a chart change, not a
rebuild. Until then the cache is protected by the security group and the private
subnets alone. Documented in `envs/prd.tfvars-example`, not forgotten.

## Availability

`multi_az_enabled` requires **both** `num_cache_clusters >= 2` **and**
`automatic_failover_enabled = true`. Setting one without the others fails the
apply, not the plan.

A single cache cluster (the dev sizing) also means `reader_endpoint` comes back
null — there is no replica to read from.

## Outputs

Seven uniform contract names shared with every other Lerian datastore root —
`mode`, `endpoint`, `port`, `security_group_id`, `secret_arn`, `secret_name`,
`identifier` — plus `reader_endpoint`, `engine_version_actual`,
`auth_token_enabled`, `transit_encryption_enabled`, `subnet_group_name`, the
cross-stack context, and `helm_values`.

`endpoint` is the raw ElastiCache primary endpoint in both modes. There is no
`dns_name`: with transit encryption on, the certificate only covers
`*.{cluster}.{region}.cache.amazonaws.com`, so an alias in front of the primary
endpoint fails TLS hostname verification — and this module ships
`transit_encryption_enabled = true` in every environment.

`endpoint` and `port` are exported separately as well as combined. `CACHE_ADDR`
consumes the combined form; the split pair is what an operator uses for the rails
whose cache variable names the chart does not state.

## Shared mode

`mode = "shared"` creates nothing and plans to zero resources. Every lookup is
gated on `mode == "dedicated"`. The module resolves the replication group
`shared-{env}-valkey` with `data "aws_elasticache_replication_group"` and the
secret `shared-{env}-valkey/auth-token` with `data "aws_secretsmanager_secret"`,
so `endpoint`, `reader_endpoint` and `port` come from the resolved group.
`security_group_id` comes back `null`.

The name is fully derived, so this root exposes no variable for it. The module's
own `shared_identifier` is the escape hatch for a shared group that is not
called `shared-{env}-valkey`.
