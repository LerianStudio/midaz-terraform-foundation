# products/lender/valkey

Cache for the lender product. Root stack over
[`_modules/valkey-elasticache`](../../../_modules/valkey-elasticache).

One root, one datastore, one state file.

> **⚠ The lender chart is not in this repository.** `helm_values` is
> deliberately **empty**. Read [`../README.md`](../README.md) before using this
> stack for anything beyond a dev sandbox.

| | |
|---|---|
| Module | `../../../_modules/valkey-elasticache` |
| State key | `aws/products/lender/valkey/terraform.tfstate` |
| Creates | `lender-{env}-valkey` (ElastiCache replication group) |
| Secret | `lender-{env}-valkey/auth-token` |
| Chart target | **unknown** — see below |

## Why `helm_values` is empty, and why Redis is the worst case

`infrastructure/K8S/helm/charts/underwriter/` has no `Chart.yaml`, no
`values.yaml` and no `templates/` — only `charts/postgresql-16.3.5.tgz` and
`charts/valkey-2.4.7.tgz`, both upstream Bitnami dependency charts. The valkey
tarball proves the product needs a cache; it says nothing about how the
application addresses one.

Redis wiring is the single worst place in this repository to guess a name,
because **the same variable behaves four different ways** across the charts that
are readable:

| Chart | shape |
|---|---|
| midaz | `REDIS_HOST` carries `"host:port"`; `REDIS_PORT` was deleted in chart 3.0 and does not exist |
| br-consignado-gw | `REDIS_HOST` carries `"host:port"`; it is the **only** Redis key the chart has |
| plugin-access-manager | `REDIS_HOST` is a **bare** host and the template appends `REDIS_PORT` itself — passing `host:port` yields `host:port:port` |
| tracer | no plain `REDIS_*` at all; only `MULTI_TENANT_REDIS_HOST` (bare) plus `MULTI_TENANT_REDIS_PORT` |

Two of the four want the port inside the host, one wants it bare and appends it,
one uses entirely different key names. There is no majority. A wrong guess fails
at connect time in production, not at plan time.

## Both candidate shapes are published

So that whoever reads the chart can wire the release without coming back here:

```bash
cd examples/aws/products/lender/valkey
terraform output -raw endpoint          # bare host          — for a split-key chart
terraform output -raw port              #                      (tracer / plugin-access-manager shape)
terraform output -raw redis_host_port   # "host:port"        — for a joined chart
                                        #                      (midaz / br-consignado-gw shape)
terraform output -raw secret_name
```

> Do **not** use `redis_host_port` for a chart that appends the port itself, as
> `plugin-access-manager` does — that yields `host:port:port`.

No password is ever an output. `secret_name` is what an External Secrets
Operator `ExternalSecret` references.

## Run it

```bash
cd examples/aws/products/lender/valkey

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/lender/valkey/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

`../../../` is **three** levels up and lands on `examples/aws`. Verified with
`terraform init -backend=false`.

Prerequisites: `infra-base/vpc`. `infra-base/eks` is optional at apply time.

## What IS verified

The chart gap does not touch the infrastructure. This root is a sibling of the
tracer and br-consignado-gw valkey roots for everything that does not depend on
chart contents: naming and tagging, `module.network` resolution, the ingress
model, the `dedicated` / `shared` switch, the seven uniform outputs, sizing per
environment, and clean `terraform validate` / `tflint` / `trivy config`.

## Ingress

Resolved by [`_modules/product-network`](../../../_modules/product-network) as
`module.network`, `enabled = var.mode == "dedicated"`: `Type=private` subnet
CIDRs plus the EKS node security group matched by
`tag:Name = "lerian-{env}-eks-node"` with the plural data source.
`check "eks_node_security_group_resolved"` lives in that module.

> `var.subnet_tag_type` (`"database"`) is the **placement** filter and goes to
> `valkey-elasticache` only. `product-network` keeps its own default
> (`"private"`), the **ingress** filter.

## Security posture

`auth_token_enabled = false` and `transit_encryption_mode = "preferred"` in all
three environments, **including production**, because the chart is not available
and neither the application's AUTH support nor its TLS trust store can be
verified. Flipping either switch blind is how a production cache goes dark.

The token **is** generated and written to `lender-{env}-valkey/auth-token`
regardless, so enabling it later is a tfvars change, not a rebuild.

## Availability

`multi_az_enabled` requires **both** `num_cache_clusters >= 2` **and**
`automatic_failover_enabled = true`. Setting one without the others fails the
apply, not the plan. A single cache cluster (the dev sizing) means
`reader_endpoint` comes back empty.

## Shared mode

`mode = "shared"` creates nothing and plans to zero resources. The module
resolves `shared-{env}-valkey` with
`data "aws_elasticache_replication_group"` and the secret
`shared-{env}-valkey/auth-token` with `data "aws_secretsmanager_secret"`, so
`endpoint`, `reader_endpoint` and `port` come from the resolved group.
`security_group_id` comes back `null`.

The name is fully derived, so this root exposes no variable for it. The module's
own `shared_identifier` is the escape hatch.
