# mongodb-documentdb

Amazon DocumentDB (MongoDB compatible) cluster for a Lerian product.

Replaces three identical pre-v2 stacks, all removed in v2:
`examples/aws/documentdb`, `examples/aws/documentdb-plugin-fee` and
`examples/aws/documentdb-plugin-crm`. They differed only in naming, backend key
and descriptions, so `product` is now an input and one module covers all three.

## What it creates (`mode = "dedicated"`)

| Resource | Name |
|---|---|
| `aws_docdb_cluster` | `{product}-{env}-docdb` |
| `aws_docdb_cluster_instance` x N | `{product}-{env}-docdb-instance-{i}` |
| `aws_docdb_subnet_group` | `{product}-{env}-docdb-subnet-group` |
| `aws_docdb_cluster_parameter_group` | `{product}-{env}-docdb-param-group` |
| `aws_security_group` + ingress rules | `{product}-{env}-docdb-sg` |
| `aws_secretsmanager_secret` | `{product}-{env}-docdb/password` |
| KMS CMK (`terraform-aws-modules/kms/aws` 1.5.0) | alias `docdb/{product}-{env}-docdb` |

Every name comes from the `naming` module, so `dev`, `stg` and `prd` coexist in a
single AWS account without collision.

## Fixes applied during the migration

| Legacy | Now | Why |
|---|---|---|
| `aws_docdb_cluster_parameter_group.name = "example"` (base stack only) | `"${module.naming.name}-param-group"` | Parameter group names are regional-unique. The literal `example` meant the second stack in the account failed, and the base stack collided with anything else named `example`. The `-plugin-fee` / `-plugin-crm` clones had already fixed this; the fixed version was taken. |
| secret `"${local.name}/documentdb-password1"` | `"${module.naming.name}/password"` | The trailing `1` was a leftover from a failed apply (Secrets Manager keeps deleted names for 7-30 days). Path is now uniform across every datastore module. |
| KMS alias `"docdb/${var.name}-${var.environment}"` | `"docdb/${module.naming.name}"` | `module.naming.name` already carries the environment; the legacy form produced `docdb/midaz-docdb-dev` style duplication. |
| No DNS record at all | still no DNS record | An intermediate revision of this module added `mongodb` / `mongodb-ro` CNAMEs in a private zone, following what the pre-v2 `examples/aws/rds/dns.tf` and `examples/aws/valkey/dns.tf` did. That was reverted: the DocumentDB certificate covers `*.docdb.amazonaws.com` only, so an alias in front of the cluster breaks TLS hostname validation, and the "stable name" argument does not hold when Helm values are generated from `terraform output` on every deploy. The pre-v2 stacks were right to have none. |
| `var.name` free-form | `product` + `environment` | Naming contract. |
| `environment` with `default = "<environment>"` | required, validated `dev\|stg\|prd` | The placeholder default was a bug: it applied literally when the caller forgot to set it. |
| Inline `ingress` block, VPC CIDR only | `aws_vpc_security_group_ingress_rule` resources | Inline blocks cannot coexist with rule resources, and the contract needs `allowed_security_group_ids` / `allowed_cidr_blocks`. |

Behaviour deliberately preserved: no egress rule is declared on the security
group (the pre-v2 stacks did not declare one either, so the provider revokes the
AWS default allow-all egress). `enabled_cloudwatch_logs_exports` still defaults to
`["audit", "profiler"]`.

## Modes

`mode` is the Lerian sharing contract, not a DocumentDB setting.

- **`dedicated`** (default) - creates everything above.
- **`shared`** - creates nothing. Resolves the cluster owned by
  `products/shared-resources/documentdb` (which runs this same module with
  `product = "shared"`), by identifier:
  - `endpoint`, `reader_endpoint`, `port`, `arn`, `identifier` and
    `master_username` via `data "aws_rds_cluster"` on `shared-{env}-docdb`;
  - secret via `data "aws_secretsmanager_secret"` on
    `shared-{env}-docdb/password`;
  - `security_group_id` and `kms_key_arn` are `null` - opening the shared
    cluster is the shared-resources/documentdb ingress' job.

`shared_identifier` overrides the cluster name, `shared_secret_name` the secret
name; both default to `""`, which derives the names above. The data source is
singular, so an unresolvable name fails the plan rather than emitting a `null`
host into the Helm values.

Note the two prefixes in `infra-base`: the foundation keeps `lerian-`
(`lerian-{env}-vpc`, `lerian-{env}-eks`), while the shared datastore tier uses
`shared-`. The `shared-` prefix only exists where a `dedicated` counterpart also
exists; the VPC and the cluster have none.

### Why `data "aws_rds_cluster"` and not `aws_docdb_cluster`

There is **no `aws_docdb_cluster` data source** in the AWS provider. The docdb
service ships exactly two — `aws_docdb_engine_version` and
`aws_docdb_orderable_db_instance` — and neither resolves an existing cluster.
DocumentDB clusters are, however, first-class RDS DB clusters in the RDS control
plane (`aws rds describe-db-clusters` lists them with `engine = "docdb"`), and
the provider's `aws_rds_cluster` data source applies no engine filter, so it
reads them.

This was **validated empirically in a real AWS account** (
us-east-2), not inferred from the provider schema: a DocumentDB cluster created
by this module and read back through `data "aws_rds_cluster"` returned
`engine = "docdb"` plus every attribute shared mode needs — `endpoint`,
`reader_endpoint`, `port` and `master_username`.

Two alternatives were considered and rejected, and neither is a pending item:
reading the shared-resources/documentdb state with `terraform_remote_state` (couples the
product stack to the infra-base state file and its backend credentials), and
taking the writer endpoint as an explicit variable (hardcodes an AWS hostname
that changes on cluster replacement, which is exactly what resolution by name
avoids).

## Inputs

### Contract

| Name | Type | Default | Description |
|---|---|---|---|
| `product` | string | - | Product owning the cluster. `shared` for shared-resources/documentdb. |
| `environment` | string | - | `dev`, `stg` or `prd`. Validated. |
| `mode` | string | `"dedicated"` | `dedicated` or `shared`. Validated. |
| `extra_tags` | map(string) | `{}` | Merged on top of the standard Lerian tags. |
| `vpc_name` | string | `""` | `tag:Name` of the VPC. Empty derives `lerian-{env}-vpc`. |
| `subnet_tag_type` | string | `"database"` | `tag:Type` used to pick subnets. The pre-v2 stack used `private`. |

### Shared mode

| Name | Type | Default | Description |
|---|---|---|---|
| `shared_identifier` | string | `""` | Cluster identifier resolved in shared mode. Empty derives `shared-{env}-docdb`. |
| `shared_secret_name` | string | `""` | Secret name resolved in shared mode. Empty derives `shared-{env}-docdb/password`. |

### Ingress

**One rule, worded identically in all five Lerian datastore modules.**

- **Any** entry in `allowed_cidr_blocks` **or** `allowed_security_group_ids` →
  exactly those sources are allowed and **nothing else**. The VPC CIDR is never
  added on top. A caller who restricts, restricts.
- **Both** lists empty → fall back to the VPC CIDR when
  `allow_vpc_cidr_ingress` is `true` (the behaviour the pre-v2
  `examples/aws/documentdb` stack had, kept so a migrated stack does not
  silently lose connectivity), or to
  **no ingress rule at all** when it is `false`.
- Rules are always scoped to the datastore port, never to a whole protocol.
- `check "ingress_is_reachable"` warns at plan time whenever the resolved set
  comes out empty, so an unreachable datastore is never silent.

| Name | Type | Default | Description |
|---|---|---|---|
| `allowed_security_group_ids` | `list(string)` | `[]` | Security group IDs allowed on the datastore port. Non-empty disables the VPC CIDR fallback. |
| `allowed_cidr_blocks` | `list(string)` | `[]` | CIDR blocks allowed on the datastore port. Non-empty disables the VPC CIDR fallback. |
| `allow_vpc_cidr_ingress` | `bool` | `true` | **Fallback only.** VPC CIDR, applied only when both lists above are empty. |

> `allow_vpc_cidr_ingress` used to be an **unconditional** widening: it opened the
> whole VPC CIDR — public subnets included — even when a restricted allow list had
> been supplied. A caller who passed a tight list believed they had restricted the
> cluster and had not. That is fixed; the flag is now a fallback and nothing else.

### Engine and sizing

| Name | Type | Default | Description |
|---|---|---|---|
| `master_username` | string (sensitive) | `"docdbadmin"` | Master username. |
| `port` | number | `27017` | Cluster port. |
| `instance_class` | string | `"db.t3.medium"` | Smallest class DocumentDB offers. Micro/small sizes are rejected at plan time - see below. |
| `instances_count` | number | `2` | 1 for dev, >= 2 for stg/prd. |
| `engine_version` | string | `null` | `null` takes the AWS default for the family. |
| `parameter_group_family` | string | `"docdb5.0"` | Must match `engine_version`. |
| `documentdb_tls` | string | `"disabled"` | `enabled` or `disabled`. Validated. |
| `backup_retention_period` | number | `7` | Days of automated backups. |
| `preferred_backup_window` | string | `"07:00-09:00"` | Backup window. |
| `enabled_cloudwatch_logs_exports` | list(string) | `["audit","profiler"]` | Log types exported. |
| `skip_final_snapshot` | bool | `true` | `false` for prd. |
| `deletion_protection` | bool | `false` | `true` for prd. |
| `apply_immediately` | bool | `false` | Skip the maintenance window. |
| `kms_deletion_window_in_days` | number | `10` | CMK deletion waiting period. |

### The instance-class floor

`db.t3.medium` is the **smallest class DocumentDB offers**. The RDS-style
micro/small sizes do not exist for this service:

```
db.t2.micro  db.t2.small  db.t3.micro  db.t3.small  db.t4g.micro  db.t4g.small
```

Passing one of them plans cleanly and then fails the `CreateDBInstance` call
minutes into the apply. A `precondition` on `aws_docdb_cluster_instance.main`
rejects them at **plan** time, naming the offending class. This is the DocumentDB
counterpart of the Performance Insights footgun `postgres-rds` guards.

## Outputs

| Name | Description |
|---|---|
| `mode` | `var.mode`, echoed. |
| `endpoint` | Raw AWS writer endpoint — the `MONGO_HOST` value. Populated in **both** modes. |
| `port` | Cluster port. Read from the resolved cluster in shared mode. |
| `security_group_id` | Cluster SG. `null` in shared mode. |
| `secret_arn` | ARN of the password secret. |
| `secret_name` | Name of the password secret. |
| `identifier` | Cluster identifier. In shared mode, the resolved `shared-{env}-docdb`. |
| `reader_endpoint` | Raw AWS reader endpoint. Resolved from the shared cluster in shared mode. |
| `arn` | Cluster ARN. Resolved from the shared cluster in shared mode. |
| `master_username` | Master username (sensitive). Read from the resolved cluster in shared mode. |
| `kms_key_arn` | CMK encrypting the storage. `null` in shared mode. |

The first seven are the uniform datastore contract and are identical across
`postgres-rds`, `mongodb-documentdb`, `valkey-elasticache`, `rabbitmq-amazonmq`
and `streaming-msk`.

`endpoint` carries the raw AWS hostname in both modes. There is no `dns_name`
output and no private zone anywhere in this repository — see the TLS caveat
below, and the same reasoning applies to the "stable name" argument: Helm values
are generated from `terraform output` on every deploy, so there is no hardcoded
host to protect.

## Usage - dedicated

```hcl
module "mongodb" {
  source = "../_modules/mongodb-documentdb"

  product     = "midaz"
  environment = var.environment

  instance_class  = "db.t3.medium"
  instances_count = 1
}
```

Helm values wiring:

```yaml
MONGO_HOST: <module.mongodb.endpoint>   # midaz-dev-docdb.cluster-xxxx.us-east-2.docdb.amazonaws.com
MONGO_PORT: "27017"
```

## Usage - shared

```hcl
module "mongodb" {
  source = "../_modules/mongodb-documentdb"

  product     = "midaz"
  environment = var.environment
  mode        = "shared"
}
```

Resolves the `shared-{env}-docdb` cluster and the `shared-{env}-docdb/password`
secret. Requires `products/shared-resources/documentdb` to have been applied with
DocumentDB enabled - it is what creates that cluster and that secret.

## TLS caveat

The DocumentDB server certificate is issued for `*.docdb.amazonaws.com`. That is
the reason this module hands out the raw AWS hosts and creates no alias in front
of them: any name outside that wildcard is rejected by a driver that validates
the hostname. Connect through `endpoint` / `reader_endpoint` and TLS works with
verification on; a private CNAME would have forced every client to
`tlsAllowInvalidHostnames`.
