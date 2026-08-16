# product-network

The network resolution every `examples/aws/products/{product}/{service}` root
stack needs, extracted once. **Pure lookup module: it creates no AWS resource.**

Before it existed, each of the four midaz service roots carried an identical
~70-line `data.tf` plus ~20 lines of `locals` plus one `check` block. At 21
products x ~3.4 services that is roughly 4,400 duplicated lines, and a fix to
the lookup would have meant 70+ identical edits.

## What it answers

| Question                                             | Output                                                    |
| ---------------------------------------------------- | --------------------------------------------------------- |
| Which VPC?                                           | `vpc_name`, `vpc_id`, `vpc_cidr_block`                     |
| Which private subnets?                               | `private_subnet_cidr_blocks`                               |
| Which EKS cluster, and which node security group?    | `eks_cluster_name`, `eks_node_security_group_ids`          |
| **Who may reach this product's datastores?**         | **`ingress_security_group_ids`, `ingress_cidr_blocks`**    |

The last row is the reason the module exists. Each datastore module
(`postgres-rds`, `mongodb-documentdb`, `valkey-elasticache`,
`rabbitmq-amazonmq`) already resolves its own VPC and subnets for the
resources it **places**. What it cannot decide is who is allowed to **reach**
them — that is a fact about the EKS cluster, and it belongs to the product
stack.

## Usage

```hcl
module "network" {
  source = "../../../_modules/product-network"

  enabled     = var.mode == "dedicated"
  environment = var.environment

  # Overrides. Both default to "" and derive from environment; a root
  # stack passes its own variables through so an operator can still override.
  vpc_name         = var.vpc_name
  eks_cluster_name = var.eks_cluster_name

  allow_private_subnet_cidr_ingress      = var.allow_private_subnet_cidr_ingress
  eks_node_security_group_lookup_enabled = var.eks_node_security_group_lookup_enabled

  allowed_security_group_ids = var.allowed_security_group_ids
  allowed_cidr_blocks        = var.allowed_cidr_blocks
}

module "postgres" {
  source = "../../../_modules/postgres-rds"

  vpc_name        = module.network.vpc_name
  subnet_tag_type = var.subnet_tag_type # "database" — NOT the module's own

  allowed_security_group_ids = module.network.ingress_security_group_ids
  allowed_cidr_blocks        = module.network.ingress_cidr_blocks
  # ...
}
```

## `enabled` — why it is not optional

A product root stack has `var.mode`. In `mode = "shared"` it creates nothing and
resolves the datastore that `products/shared-resources` owns, by name — a
`data` lookup on the shared resource plus one on its Secrets Manager secret, and
nothing else. The VPC may not exist at all in that deployment, so **the plan
must not look it up**.

Every data source in this module carries `count = var.enabled ? 1 : 0`. The
caller passes:

```hcl
enabled = var.mode == "dedicated"
```

With `enabled = false`: `vpc_id` and `vpc_cidr_block` are `null`, every list
output is `[]`, the two derived name outputs still resolve (they are pure
string derivations of `var.environment`), and the `check` block passes.

## Two different `subnet_tag_type` values — do not cross them

| Where                            | Default      | Selects                                             |
| -------------------------------- | ------------ | --------------------------------------------------- |
| `product-network.subnet_tag_type` | `"private"`  | subnets whose CIDRs become **ingress**               |
| datastore module `subnet_tag_type` | `"database"` | subnets the instance is **placed in** (subnet group) |

A root stack exposes one variable, `var.subnet_tag_type` (`"database"`), and
passes it to the **datastore** module only. This module is left at its default.
Passing `"database"` here would authorise the wrong CIDRs — the database subnets
have no EKS nodes in them.

## The EKS node security group lookup

`data "aws_security_groups"` — **plural** — on purpose. The singular
`data "aws_security_group"` fails the plan when nothing matches, which would
make every product stack un-appliable until `infra-base/eks` exists. The plural
form returns an empty list instead, so:

- the plan succeeds before the cluster exists;
- the ingress rule appears on the first apply after it does;
- `check "eks_node_security_group_resolved"` turns that window into a visible
  warning rather than a silent gap.

The match is on `tag:Name = "{eks_cluster_name}-node"`, which
`terraform-aws-modules/eks` sets verbatim. The security group's own `name`
attribute carries a generated suffix (the module uses `name_prefix`), so the tag
is the only stable handle — filtering on `group-name` would not match.

The `check` block lives in this module, not in the callers. `check` blocks are
evaluated inside child modules exactly as they are in a root; the warning
surfaces in the caller's plan output carrying this module's address. Writing it
here is what keeps the message from being copy-pasted 70 times.

## Deploy order

```
infra-base/vpc -> products/{product}/{service}
```

`infra-base/eks` can come before or after. When it comes after, the first apply
of a product stack emits the `eks_node_security_group_resolved` warning and
authorises ingress from the private subnet CIDRs only; re-apply after the
cluster exists to pick the security group up.

## Inputs

| Name                                     | Type           | Default     | Description                                                              |
| ---------------------------------------- | -------------- | ----------- | ------------------------------------------------------------------------ |
| `enabled`                                | `bool`         | `true`      | Perform the lookups. Set to `var.mode == "dedicated"`.                    |
| `environment`                            | `string`       | —           | `dev`, `stg` or `prd`. Validated.                                        |
| `vpc_name`                               | `string`       | `""`        | Empty derives `lerian-{environment}-vpc`.                                |
| `eks_cluster_name`                       | `string`       | `""`        | Empty derives `lerian-{environment}-eks`.                                |
| `subnet_tag_type`                        | `string`       | `"private"` | `tag:Type` of the subnets whose CIDRs become ingress.                    |
| `allow_private_subnet_cidr_ingress`      | `bool`         | `true`      | Fold the private subnet CIDRs into `ingress_cidr_blocks`.                |
| `eks_node_security_group_lookup_enabled` | `bool`         | `true`      | Resolve the node SG by tag and fold it into `ingress_security_group_ids`.|
| `allowed_security_group_ids`             | `list(string)` | `[]`        | Extra security groups.                                                   |
| `allowed_cidr_blocks`                    | `list(string)` | `[]`        | Extra CIDR blocks.                                                       |

## Outputs

| Name                          | Description                                                                 |
| ----------------------------- | --------------------------------------------------------------------------- |
| `vpc_name`                    | Derived or overridden `tag:Name` of the VPC.                                 |
| `vpc_id`                      | ID of the resolved VPC. `null` when `enabled = false`.                       |
| `vpc_cidr_block`              | Primary CIDR of the VPC. `null` when `enabled = false`. Not used for ingress.|
| `eks_cluster_name`            | Derived or overridden EKS cluster name. Note the `lerian-` prefix: the cluster is infra-base foundation, not part of the `shared-` datastore tier. |
| `private_subnet_cidr_blocks`  | Sorted CIDRs of the `subnet_tag_type` subnets.                               |
| `eks_node_security_group_ids` | Sorted IDs matched by `tag:Name = "{cluster}-node"`.                          |
| `ingress_security_group_ids`  | **Feed to the datastore module's `allowed_security_group_ids`.**             |
| `ingress_cidr_blocks`         | **Feed to the datastore module's `allowed_cidr_blocks`.**                    |
