# products/br-sisbajud/valkey

Cache for the br-sisbajud SISBAJUD plugin. Root stack over
[`_modules/valkey-elasticache`](../../../_modules/valkey-elasticache).

One root, one datastore, one state file. See [`../README.md`](../README.md) for
the product-level picture: deploy order, the shared-vs-dedicated model, and the
full Helm mapping.

| | |
|---|---|
| Module | `../../../_modules/valkey-elasticache` |
| State key | `aws/products/br-sisbajud/valkey/terraform.tfstate` |
| Creates | `br-sisbajud-{env}-valkey` (ElastiCache replication group) |
| Secret | `br-sisbajud-{env}-valkey/auth-token` |
| Chart target | `brSisbajud.configmap` (`REDIS_HOST`) |
| Chart verified | br-sisbajud 1.1.0, appVersion `1.0.0-beta.109` |

The CRM deployment has no Redis variables at all.

## Run it

```bash
cd examples/aws/products/br-sisbajud/valkey

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/br-sisbajud/valkey/terraform.tfstate"

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
   Note the `lerian` prefix on both: they belong to `infra-base`, not to br-sisbajud.
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

## `REDIS_HOST` carries `host:port`

This is the one place where copying `endpoint` straight into the chart produces a
broken release — and it fails *quietly*.

The br-sisbajud chart never had a `REDIS_PORT` variable at all. The port lives
inside `REDIS_HOST`:

- `values-template.yaml:18` comments the key `REQUIRED — managed Valkey host:port`
- the chart's in-cluster fallback renders `<svc>.<ns>.svc.cluster.local.:6379`
  (`templates/configmap.yaml:8`)
- the `wait-for-dependencies` initContainer **splits `REDIS_HOST` on `:`** to
  recover host and port, defaulting to `6379` when nothing follows the colon
  (`templates/deployment.yaml:66-68`)

So a bare hostname does not error: the probe succeeds against 6379 and the
application is handed a host with no port.

`helm_values` therefore emits `"${endpoint}:${port}"`.

> This is the same *shape* as `products/midaz/valkey` for a different *reason*.
> midaz lost `REDIS_PORT` in a 3.0 chart migration; here the variable never
> existed. Do not carry the midaz explanation across.

## The chart defines exactly two Redis variables

`REDIS_HOST` and `REDIS_PASSWORD`. A grep over the whole chart returns nothing
else. In particular these midaz keys **do not exist** and must not be emitted:

| midaz key | Status in br-sisbajud |
|---|---|
| `REDIS_TLS` | does not exist |
| `REDIS_DB` | does not exist |
| `MULTI_TENANT_REDIS_HOST` | does not exist |
| `MULTI_TENANT_REDIS_PORT` | does not exist |
| `MULTI_TENANT_REDIS_TLS` | does not exist |
| `REDIS_USER` / `REDIS_USERNAME` | does not exist |

`helm_values` here has **one key**. That is not an omission — it is the whole
non-secret surface the chart exposes.

### Consequence: TLS posture is not communicable

There is no `REDIS_TLS` key, so nothing in the values can tell the client to
speak TLS. `transit_encryption_mode` therefore stays `"preferred"` in every
environment: ElastiCache accepts TLS and plaintext alike, the client keeps using
plaintext, and the connection still works. Flipping it to `"required"` locks the
application out with nothing in the values to explain why.

## The auth token exists but is not enforced

`auth_token_enabled` is `false` in every environment, including production. This
is a **documented gap**, spelled out in `envs/prd.tfvars-example`, not an
oversight:

- The chart's own comment on `REDIS_PASSWORD` is *"set if the external Redis
  requires auth"* (`values-template.yaml:29`) — optional on both sides.
- With `transit_encryption_mode = "preferred"` the connection is plaintext, and
  sending an ElastiCache AUTH token over plaintext hands the credential to
  anything on the path. Enforcing the token is only worth doing together with
  `"required"`, which the chart cannot currently be told to use (see above).

The token **is** generated and written to `br-sisbajud-{env}-valkey/auth-token`
regardless, so flipping both switches later is a tfvars change plus a chart
change, not a rebuild. Until then the cache is protected by the security group
and the private subnets alone.

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

`endpoint` and `port` are exported separately as well as combined. The chart
only consumes the combined form, but an operator debugging a security group
needs the port on its own.

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
