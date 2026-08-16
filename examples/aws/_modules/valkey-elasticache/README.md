# valkey-elasticache

Valkey on Amazon ElastiCache for Lerian products. Thin wrapper over
[`terraform-aws-modules/elasticache/aws ~> 1.6.0`](https://registry.terraform.io/modules/terraform-aws-modules/elasticache/aws/1.6.0)
with `engine = "valkey"`, plus the Lerian naming contract, self-resolving network
lookups, and the `dedicated` / `shared` provisioning modes.

Migrated from the pre-v2 `examples/aws/valkey` stack, removed in v2.

## What it creates (`mode = "dedicated"`)

| Resource                                | Name                                    |
| --------------------------------------- | --------------------------------------- |
| ElastiCache replication group           | `{product}-{environment}-valkey`         |
| Cache subnet group                      | `{product}-{environment}-valkey`         |
| Cache parameter group                   | `{product}-{environment}-valkey`         |
| Security group (name-prefixed)          | `{product}-{environment}-valkey-…`       |
| Secrets Manager secret (raw auth token) | `{product}-{environment}-valkey/auth-token` |

All of those come from the `naming` module, which is what lets `dev`, `stg` and
`prd` coexist in a single AWS account.

### ElastiCache identifier limits

`replication_group_id` accepts **at most 40 characters** and **no underscores**.
The derived name is `{product}-{environment}-valkey`, so the worst case is
24 (the `naming` module's product ceiling) + 1 + 3 + 1 + 6 = **35 characters** —
inside the limit for every legal product name. The `naming` module's
`product`/`component` regexes already reject underscores.

Both invariants are re-checked as plan-time `precondition`s on
`aws_secretsmanager_secret.auth` rather than trusted, so a future change to the
naming convention fails with a readable message instead of an opaque AWS API
error. A third precondition rejects `auth_token_enabled = true` without
`transit_encryption_enabled = true`.

## What it creates (`mode = "shared"`)

Nothing. It resolves the replication group that `products/shared-resources/valkey`
already created — **by name, through
`data "aws_elasticache_replication_group"`** — and echoes it through the uniform
outputs:

- `endpoint`, `port`, `identifier`, `reader_endpoint`, `auth_token_enabled` →
  read from `data "aws_elasticache_replication_group"` on
  `shared-{environment}-valkey`
- `secret_arn` / `secret_name` → looked up from
  `shared-{environment}-valkey/auth-token`
- `security_group_id`, `subnet_group_name`, `engine_version_actual` → `null`
  (the last one because the data source does not report it)

`shared-{environment}-valkey` is exactly what `products/shared-resources/valkey`
creates with `product = "shared"`. Override the lookup with `shared_identifier`
only when the shared tier was named outside this Terraform. The data source is
singular, so an unresolvable name fails the plan instead of emitting a `null`
endpoint into the Helm values.

Note the two prefixes in `infra-base`: the foundation keeps `lerian-`
(`lerian-{env}-vpc`, `lerian-{env}-eks`), while the shared datastore tier uses
`shared-`. The `shared-` prefix only exists where a `dedicated` counterpart also
exists; the VPC and the cluster have none.

Opening the shared group's security group to the consuming product is the
responsibility of the `shared-resources/valkey` stack, not of this module.

## Inputs

### Naming and mode

| Name          | Type          | Default       | Description                                                                  |
| ------------- | ------------- | ------------- | ---------------------------------------------------------------------------- |
| `product`     | `string`      | —             | Product this datastore belongs to. `shared` for the shared group.            |
| `environment` | `string`      | —             | `dev`, `stg` or `prd`. Validated.                                            |
| `mode`        | `string`      | `"dedicated"` | `dedicated` provisions the group; `shared` provisions nothing. Validated.     |
| `extra_tags`  | `map(string)` | `{}`          | Merged on top of the standard Lerian tag set.                                |

### Network

| Name                         | Type           | Default      | Description                                                                        |
| ---------------------------- | -------------- | ------------ | ---------------------------------------------------------------------------------- |
| `vpc_name`                   | `string`       | `""`         | `tag:Name` of the VPC. Empty derives `lerian-{environment}-vpc`.                   |
| `subnet_tag_type`            | `string`       | `"database"` | `tag:Type` used to select the subnets for the cache subnet group.                  |

### Ingress

**One rule, worded identically in all five Lerian datastore modules.**

- **Any** entry in `allowed_cidr_blocks` **or** `allowed_security_group_ids` →
  exactly those sources are allowed and **nothing else**. The VPC CIDR is never
  added on top. A caller who restricts, restricts.
- **Both** lists empty → fall back to the VPC CIDR when
  `allow_vpc_cidr_ingress` is `true` (the pre-refactor behaviour, kept so a
  migrated stack does not silently lose connectivity), or to **no ingress rule
  at all** when it is `false`.
- Rules are always scoped to the datastore port, never to a whole protocol.
- `check "ingress_is_reachable"` warns at plan time whenever the resolved set
  comes out empty, so an unreachable datastore is never silent.

| Name                         | Type           | Default | Description                                                                                  |
| ---------------------------- | -------------- | ------- | -------------------------------------------------------------------------------------------- |
| `allowed_security_group_ids` | `list(string)` | `[]`    | Security group IDs allowed on the datastore port. Non-empty disables the VPC CIDR fallback.  |
| `allowed_cidr_blocks`        | `list(string)` | `[]`    | CIDR blocks allowed on the datastore port. Non-empty disables the VPC CIDR fallback.         |
| `allow_vpc_cidr_ingress`     | `bool`         | `true`  | **Fallback only.** VPC CIDR, applied only when both lists above are empty.                   |

The rules are expressed through the upstream module's `security_group_rules`
input, so they land on the security group ElastiCache actually attaches.

### Shared mode

| Name                 | Type     | Default | Description                                                                                 |
| -------------------- | -------- | ------- | ------------------------------------------------------------------------------------------- |
| `shared_identifier`  | `string` | `""`    | Override the replication group id resolved in shared mode. Empty derives `shared-{environment}-valkey`. |
| `shared_secret_name` | `string` | `""`    | Override the shared secret lookup. Empty derives `shared-{environment}-valkey/auth-token`.   |

### Engine and sizing

| Name                         | Type                              | Default                              | Description                                                     |
| ---------------------------- | --------------------------------- | ------------------------------------ | --------------------------------------------------------------- |
| `engine_version`             | `string`                          | `"7.2"`                              | Valkey engine version.                                          |
| `parameter_group_family`     | `string`                          | `"valkey7"`                          | Parameter group family.                                         |
| `parameters`                 | `list(object({name,value}))`      | `[{latency-tracking = "yes"}]`       | Parameters to apply.                                            |
| `port`                       | `number`                          | `6379`                               | Port the cache nodes listen on.                                 |
| `node_type`                  | `string`                          | `"cache.m7g.large"`                  | Node type.                                                      |
| `num_cache_clusters`         | `number`                          | `null`                               | Nodes in the group. Must be ≥ 2 with `multi_az_enabled`.        |
| `automatic_failover_enabled` | `bool`                            | `null`                               | Automatic promotion of a replica. Required for Multi-AZ.        |
| `multi_az_enabled`           | `bool`                            | `false`                              | Multi-AZ support.                                               |
| `snapshot_retention_limit`   | `number`                          | `null`                               | Days of automatic snapshot retention.                           |

### Security and maintenance

| Name                         | Type     | Default                    | Description                                                                                     |
| ---------------------------- | -------- | -------------------------- | ----------------------------------------------------------------------------------------------- |
| `at_rest_encryption_enabled` | `bool`   | `true`                     | Encryption at rest.                                                                             |
| `transit_encryption_enabled` | `bool`   | `true`                     | Encryption in transit.                                                                          |
| `transit_encryption_mode`    | `string` | `"preferred"`              | `preferred` or `required`. Validated.                                                           |
| `auth_token_enabled`         | `bool`   | `false`                    | Whether ElastiCache enforces the generated token. The token is stored either way. See below.     |
| `maintenance_window`         | `string` | `"mon:00:00-mon:03:00"`    | Maintenance window.                                                                             |
| `apply_immediately`          | `bool`   | `false`                    | Apply modifications immediately instead of in the maintenance window.                            |

## Outputs

The first seven are the uniform datastore contract, identical in every
`_modules` datastore.

| Name                         | Description                                                                          |
| ---------------------------- | ------------------------------------------------------------------------------------ |
| `mode`                       | `var.mode`, echoed.                                                                  |
| `endpoint`                   | Raw AWS primary endpoint address. Populated in **both** modes.                        |
| `port`                       | Valkey port. Read from the resolved group in shared mode.                             |
| `security_group_id`          | Security group attached to the group. `null` in shared mode.                           |
| `secret_arn`                 | ARN of the auth-token secret (created in dedicated mode, looked up in shared mode).    |
| `secret_name`                | Name of the auth-token secret.                                                        |
| `identifier`                 | ElastiCache replication group ID. In shared mode, the resolved `shared-{environment}-valkey`. |
| `reader_endpoint`            | Reader endpoint address. Resolved from the shared group in shared mode.                |
| `engine_version_actual`      | Running cache engine version. `null` in shared mode — the data source does not report it. |
| `auth_token_enabled`         | Whether ElastiCache is enforcing the stored token. Read from the resolved group in shared mode. |
| `transit_encryption_enabled` | Whether in-transit encryption is on. Echoed from the variable, so in shared mode it reflects what the caller declared, not what the shared group runs. |
| `subnet_group_name`          | Cache subnet group name. `null` in shared mode.                                        |

`endpoint` carries the raw AWS hostname because that is the only shape that
works with TLS on, and this module runs with `transit_encryption_enabled = true`
by default: the ElastiCache in-transit certificate covers
`*.{cluster}.{region}.cache.amazonaws.com` only, so a private CNAME in front of
the primary endpoint fails hostname verification. There is no `dns_name` output
and no private zone anywhere in this repository. The "stable name" argument does
not apply either — Helm values are generated from `terraform output` on every
deploy, so there is no hardcoded host to protect.

Helm still receives `REDIS_HOST` as a single `"host:port"` string; it is now
assembled from the raw `endpoint` and `port`.

The secret holds the raw token string (no JSON envelope), matching the
pre-refactor stack.

## Usage — `mode = "dedicated"`

```hcl
module "valkey" {
  source = "../../_modules/valkey-elasticache"

  product     = "midaz"
  environment = var.environment
  mode        = "dedicated"

  node_type          = "cache.t4g.micro"
  num_cache_clusters = 1
  multi_az_enabled   = false

  transit_encryption_enabled = true
  transit_encryption_mode    = "preferred"

  allowed_security_group_ids = [module.eks.node_security_group_id]
}
```

## Usage — `mode = "shared"`

```hcl
module "valkey" {
  source = "../../_modules/valkey-elasticache"

  product     = "midaz"
  environment = var.environment
  mode        = "shared"
}

# Same output name either way: the raw primary endpoint of shared-dev-valkey in
# shared mode, of midaz-dev-valkey in dedicated mode.
output "redis_host" {
  value = "${module.valkey.endpoint}:${module.valkey.port}"
}
```

## Migration notes (from the pre-v2 `examples/aws/valkey` stack)

| Before                                                                      | After                                                                     |
| --------------------------------------------------------------------------- | ------------------------------------------------------------------------- |
| `var.name` used raw for `replication_group_id`, `subnet_group_name`, `parameter_group_name` | all naming-derived, so they no longer collide across environments |
| **Secret `"${var.name}-auth/test"`** — hardcoded `/test` suffix (`credentials.tf:14`) | `"{product}-{environment}-valkey/auth-token"`                     |
| Standalone `aws_security_group.valkey` created but never attached to anything, while the upstream module created a second one | one security group, the module's; `security_group_id` returns the one actually in the data path |
| `security_group_rules` hardcoded to the VPC CIDR                             | built from `allowed_cidr_blocks` / `allowed_security_group_ids`, VPC CIDR as fallback |
| CNAME `"${var.dns_name}.${var.dns_zone_name}"` in a private zone, default `redis` | no DNS record at all; `endpoint` hands out the raw ElastiCache primary endpoint |
| `auth_token` commented out in `main.tf`                                      | `auth_token_enabled` (default `false`, i.e. unchanged behaviour) wires the stored token when flipped |
| `var.additional_tags`                                                        | `extra_tags`, merged inside the naming module                             |
| `vpc_name` required                                                          | optional, derives `lerian-{environment}-vpc`                             |
| `required_version >= 1.0.0`                                                   | `>= 1.5.0`, per the module contract                                       |

`security_group_use_name_prefix` keeps its upstream default of `true`: the prefix
is naming-derived (collision-safe) and prefix mode lets the group be replaced
without a name conflict.
