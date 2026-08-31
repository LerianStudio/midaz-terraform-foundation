# postgres-rds

PostgreSQL on Amazon RDS for Lerian products. Thin wrapper over
[`terraform-aws-modules/rds/aws ~> 6.0`](https://registry.terraform.io/modules/terraform-aws-modules/rds/aws/6.12.0)
that adds the Lerian naming contract, self-resolving network lookups, and the
`dedicated` / `shared` provisioning modes.

Migrated from the pre-v2 `examples/aws/rds` stack, removed in v2.

## What it creates (`mode = "dedicated"`)

| Resource                                          | Name                                          |
| ------------------------------------------------- | --------------------------------------------- |
| RDS instance (primary)                            | `{product}-{environment}-postgres`             |
| RDS instance (read replica, optional)             | `{product}-{environment}-postgres-replica`     |
| DB subnet group                                   | `{product}-{environment}-postgres-subnet-group` |
| DB parameter group (name-prefixed)                | `{product}-{environment}-postgres…`            |
| Security group                                    | `{product}-{environment}-postgres-sg`          |
| Secrets Manager secret (JSON master credentials)  | `{product}-{environment}-postgres/password`    |
| IAM enhanced-monitoring role                      | `{product}-{environment}-postgres-monitoring-role` |
| IAM enhanced-monitoring role (replica)            | `{product}-{environment}-postgres-replica-monitoring-role` |

Every one of those names is derived from the `naming` module, which is what lets
`dev`, `stg` and `prd` coexist in a single AWS account. `monitoring_role_name`
is passed with `monitoring_role_use_name_prefix = false`, so the naming module is
the only thing preventing an IAM role collision across environments.

## What it creates (`mode = "shared"`)

Nothing. It resolves the instance that `products/shared-resources/postgres` already
created — **by name, through `data "aws_db_instance"`** — and echoes it through
the uniform outputs:

- `endpoint`, `port`, `identifier`, `database_name`, `username` → read from
  `data "aws_db_instance"` on `shared-{environment}-postgres`
- `secret_arn` / `secret_name` → looked up from
  `shared-{environment}-postgres/password`
- `security_group_id`, `subnet_group_name`, `replica_endpoint` → `null`

`shared-{environment}-postgres` is exactly what `products/shared-resources/postgres`
creates with `product = "shared"`. Override the lookup with `shared_identifier`
only when the shared tier was named outside this Terraform. The data source is
singular, so an unresolvable name fails the plan instead of emitting a `null`
endpoint into the Helm values.

Note the two prefixes in `infra-base`: the foundation keeps `lerian-`
(`lerian-{env}-vpc`, `lerian-{env}-eks`), while the shared datastore tier uses
`shared-`. The `shared-` prefix only exists where a `dedicated` counterpart also
exists; the VPC and the cluster have none, so labelling them `shared` would
carry no information.

Opening the shared instance's security group to the consuming product is the
responsibility of the `shared-resources/postgres` stack, not of this module.

## Inputs

### Naming and mode

| Name          | Type          | Default       | Description                                                                   |
| ------------- | ------------- | ------------- | ----------------------------------------------------------------------------- |
| `product`     | `string`      | —             | Product this datastore belongs to. `shared` for the shared instance.          |
| `environment` | `string`      | —             | `dev`, `stg` or `prd`. Validated.                                             |
| `mode`        | `string`      | `"dedicated"` | `dedicated` provisions the instance; `shared` provisions nothing. Validated.   |
| `extra_tags`  | `map(string)` | `{}`          | Merged on top of the standard Lerian tag set.                                 |

### Network

| Name                         | Type           | Default      | Description                                                                             |
| ---------------------------- | -------------- | ------------ | --------------------------------------------------------------------------------------- |
| `vpc_name`                   | `string`       | `""`         | `tag:Name` of the VPC. Empty derives `lerian-{environment}-vpc`.                        |
| `subnet_tag_type`            | `string`       | `"database"` | `tag:Type` used to select the subnets for the DB subnet group.                          |

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

### Shared mode

| Name                 | Type     | Default | Description                                                                                |
| -------------------- | -------- | ------- | ------------------------------------------------------------------------------------------ |
| `shared_identifier`  | `string` | `""`    | Override the RDS DB instance identifier resolved in shared mode. Empty derives `shared-{environment}-postgres`. |
| `shared_secret_name` | `string` | `""`    | Override the shared secret lookup. Empty derives `shared-{environment}-postgres/password`. |

### Engine

| Name                   | Type                | Default        | Description                       |
| ---------------------- | ------------------- | -------------- | --------------------------------- |
| `engine`               | `string`            | `"postgres"`   | Database engine type.             |
| `engine_version`       | `string`            | `"16"`         | Engine version. MAJOR-only on purpose — see the variable description. |
| `family`               | `string`            | `"postgres16"` | Parameter group family.           |
| `major_engine_version` | `string`            | `"16"`         | Major engine version.             |
| `database_name`        | `string`            | —              | Database created on the instance. |
| `username`             | `string`            | `"postgres"`   | Master user.                      |
| `port`                 | `number`            | `5432`         | Database port.                    |
| `parameters`           | `list(map(string))` | `[]`           | DB parameters to apply.           |

### Sizing, replica, maintenance, monitoring

| Name                                    | Type     | Default                    | Description                                            |
| --------------------------------------- | -------- | -------------------------- | ------------------------------------------------------ |
| `instance_class`                        | `string` | `"db.m7g.large"`           | Instance type.                                         |
| `allocated_storage`                     | `number` | `20`                       | Allocated storage in GB.                               |
| `max_allocated_storage`                 | `number` | `100`                      | Storage autoscaling ceiling in GB.                     |
| `multi_az`                              | `bool`   | `false`                    | Multi-AZ primary.                                      |
| `create_read_replica`                   | `bool`   | `false`                    | Create a read replica.                                 |
| `read_replica_instance_class`           | `string` | `null`                     | Instance class of the replica.                         |
| `read_replica_multi_az`                 | `bool`   | `false`                    | Multi-AZ replica.                                      |
| `maintenance_window`                    | `string` | `"Mon:00:00-Mon:03:00"`    | Maintenance window.                                    |
| `backup_window`                         | `string` | `"03:00-06:00"`            | Backup window.                                         |
| `backup_retention_period`               | `number` | `7`                        | Days of backup retention.                              |
| `skip_final_snapshot`                   | `bool`   | `false`                    | Skip the final snapshot on destroy.                    |
| `deletion_protection`                   | `bool`   | `true`                     | Deletion protection.                                   |
| `monitoring_interval`                   | `number` | `60`                       | Enhanced Monitoring interval in seconds.               |
| `create_monitoring_role`                | `bool`   | `true`                     | Create the enhanced-monitoring IAM role.               |
| `performance_insights_enabled`          | `bool`   | `true`                     | Enable Performance Insights. See the footgun note below. |
| `performance_insights_retention_period` | `number` | `7`                        | Performance Insights retention in days.                |
| `enabled_cloudwatch_logs_exports`       | `list(string)` | `["postgresql","upgrade"]` | Log types exported to CloudWatch.                |
| `create_cloudwatch_log_group`           | `bool`   | `true`                     | Create the CloudWatch log groups for those exports.    |

### Performance Insights on the smallest instance classes

`performance_insights_enabled` defaults to **`true`** on purpose: production must
not lose query-level observability because nobody remembered to switch it on.

AWS does **not** support Performance Insights on these classes:

```
db.t2.micro  db.t2.small  db.t3.micro  db.t3.small  db.t4g.micro  db.t4g.small
```

Which is exactly the range the dev tfvars live in. AWS only rejects the
combination minutes into `terraform apply`, so this module rejects it at **plan**
time instead, via a `precondition` on `aws_secretsmanager_secret.this` that names
the offending class and lists the unsupported set. It covers
`read_replica_instance_class` too.

Dev and staging stacks on `db.t4g.micro` therefore have to set
`performance_insights_enabled = false` explicitly. The alternative — flipping the
default to `false` — was rejected: it silences observability in production by
omission, which is the more expensive failure of the two.

## Outputs

The first seven are the uniform datastore contract, identical in every
`_modules` datastore.

| Name                | Description                                                                           |
| ------------------- | ------------------------------------------------------------------------------------- |
| `mode`              | `var.mode`, echoed.                                                                   |
| `endpoint`          | Raw AWS hostname — the Helm `DB_HOST`. Populated in **both** modes.                    |
| `port`              | Database port. Read from the resolved instance in shared mode.                         |
| `security_group_id` | Security group attached to the instance. `null` in shared mode.                        |
| `secret_arn`        | ARN of the credentials secret (created in dedicated mode, looked up in shared mode).   |
| `secret_name`       | Name of the credentials secret.                                                        |
| `identifier`        | RDS DB instance identifier. In shared mode, the resolved `shared-{environment}-postgres`. |
| `database_name`     | Database on the instance. Read from the resolved instance in shared mode.              |
| `username`          | Master username. Read from the resolved instance in shared mode.                       |
| `replica_endpoint`  | Read replica hostname. `null` when no replica, and `null` in shared mode.              |
| `replica_identifier`| Read replica DB instance identifier. `null` when no replica.                           |
| `subnet_group_name` | DB subnet group name. `null` in shared mode.                                           |

`endpoint` carries the raw AWS hostname because that is the only shape that
works with TLS on: the RDS server certificate covers
`*.{region}.rds.amazonaws.com` only, so a private CNAME in front of the instance
fails hostname verification on any client that checks it. There is no
`dns_name` output and no private zone anywhere in this repository. The
"stable name" argument does not apply either — Helm values are generated from
`terraform output` on every deploy, so there is no hardcoded host to protect.

The secret holds a JSON document with `username`, `password`, `engine`, `host`,
`port` and `dbname`.

## The generated password is URL-safe by construction

`random_password.master` draws from **alphanumerics plus `-` `_` `.` `~`** at
**32 characters**. That symbol set is the RFC 3986 §2.3 *unreserved* production
— the characters that carry no syntactic meaning anywhere in a URI and so never
need percent-encoding.

**This is deliberate and it is not a style choice. Do not widen it.**

Consumers interpolate the password **raw** into a DSN, with no escaping:

| Consumer | How the password reaches it |
|---|---|
| `br-sfn` | baked-flavour migration Jobs build `postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}?sslmode=…` by interpolation (`charts/br-sfn/templates/_helpers.tpl:604`). The chart states the rule in words: *"Postgres passwords must be URL-safe (no `@ : / ? # %`)"* |
| `plugin-br-pix-switch` | every datastore is reached through a URL — `DATABASE_URL`, `MONGO_URL`, `VALKEY_URL`, `RABBITMQ_URI` |

The previous set was `!#$%^&*()-_=+[]{}<>:?`. Four of its members break a DSN,
each differently: `#` truncates at the fragment, `%` opens an invalid
percent-escape, `?` starts the query string, `:` splits userinfo so the password
is read as `host:port`. At 16 characters over ~20 symbols, drawing at least one
was the **likely** outcome — an intermittent failure that reproduces on roughly
every other rebuild and points at nothing.

Entropy went **up**, not down: 32 characters over the 66-symbol alphabet is
~193 bits against the ~104 bits the old 16-character password carried.

### Engine limits this was checked against

| Constraint | RDS master password | This module |
|---|---|---|
| Length | 8–128 (PostgreSQL) | 32 |
| Forbidden | `/` `"` `@` and space | none emitted |
| Complexity rule | none | all four character classes forced via `min_*` |

`-_.~` collides with nothing on the blocklist, so the set is legal on every RDS
engine this module can be pointed at, not only PostgreSQL.

> **Sibling modules differ on purpose.** `mongodb-documentdb` and
> `rabbitmq-amazonmq` use the same `-_.~`. `valkey-elasticache` uses **`-`
> alone**, because the ElastiCache AUTH token is governed by an *allowlist*
> (`! & # $ ^ < > -`) rather than a blocklist, and `-` is its only member that
> is also RFC 3986 unreserved. See that module's README.

### Changing this rotates the password

`length`, `override_special` and the `min_*` floors are all inputs to
`random_password`, so editing any of them **regenerates the value** and the next
`apply` issues a `ModifyDBInstance` that rotates the RDS master password.

Plan for it rather than discovering it: the new value lands in
`{product}-{environment}-postgres/password`, and any workload holding the old
one keeps failing authentication until External Secrets resyncs the Kubernetes
Secret and the pods restart. Roll it in a maintenance window, dev first.

## Usage — `mode = "dedicated"`

```hcl
module "postgres" {
  source = "../../_modules/postgres-rds"

  product     = "midaz"
  environment = var.environment
  mode        = "dedicated"

  database_name = "midaz"

  instance_class          = "db.t4g.micro"
  allocated_storage       = 20
  multi_az                = false
  backup_retention_period = 1
  deletion_protection     = false
  skip_final_snapshot     = true

  allowed_security_group_ids = [module.eks.node_security_group_id]
}
```

## Usage — `mode = "shared"`

```hcl
module "postgres" {
  source = "../../_modules/postgres-rds"

  product     = "midaz"
  environment = var.environment
  mode        = "shared"

  database_name = "midaz"
}

# Same output name either way: the raw hostname of shared-dev-postgres in shared
# mode, of midaz-dev-postgres in dedicated mode.
output "db_host" {
  value = module.postgres.endpoint
}
```

## Migration notes (from the pre-v2 `examples/aws/rds` stack)

| Before                                                        | After                                                          |
| ------------------------------------------------------------- | -------------------------------------------------------------- |
| `var.name` free-form base name                                | `product` + `environment`, names derived from the naming module |
| Secret `"${var.name}/rds"`                                     | `"{product}-{environment}-postgres/password"`                  |
| `monitoring_role_name = "${var.name}-monitoring-role"`         | naming-derived, so it no longer collides across environments    |
| CNAME `"${var.name}.${var.dns_zone_name}"` in a private zone   | no DNS record at all; `endpoint` hands out the raw RDS hostname |
| `var.additional_tags`                                          | `extra_tags`, merged inside the naming module                  |
| Inline `ingress` block hardcoded to the VPC CIDR               | `allowed_cidr_blocks` / `allowed_security_group_ids`, VPC CIDR as fallback |
| `vpc_name` required                                            | optional, derives `lerian-{environment}-vpc`                   |
| Replica inherited `manage_master_user_password = true`          | pinned to `false`; RDS rejects a managed master password on a replica |

`parameter_group_use_name_prefix` deliberately keeps its upstream default of
`true`. The prefix itself is naming-derived (collision-safe), and the prefix mode
is what allows a `family` change to create the replacement parameter group before
destroying the old one.

No egress rule is declared on the security group, matching the pre-refactor
stack: an RDS instance does not initiate outbound connections.
