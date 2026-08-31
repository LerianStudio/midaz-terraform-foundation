################################################################################
# postgres-rds
#
# Thin wrapper over terraform-aws-modules/rds/aws for the Lerian PostgreSQL
# datastore. Migrated from the pre-v2 examples/aws/rds stack (removed in v2)
# with three changes:
#
#   1. every name comes from the naming module ({product}-{environment}-postgres)
#      so dev/stg/prd can share one AWS account without colliding;
#   2. the Secrets Manager path is "{name}/password" instead of "{name}/rds";
#   3. mode = "shared" makes the module create nothing and resolve the instance
#      that products/shared-resources/postgres already created.
################################################################################

locals {
  component = "postgres"
  create    = var.mode == "dedicated"

  vpc_name = var.vpc_name != "" ? var.vpc_name : "lerian-${var.environment}-vpc"

  vpc_id     = try(data.aws_vpc.selected[0].id, null)
  vpc_cidr   = try(data.aws_vpc.selected[0].cidr_block, "")
  subnet_ids = try(data.aws_subnets.selected[0].ids, [])

  ################################################################################
  # Ingress — THE single rule, identical in all five datastore modules
  #
  #   any entry in allowed_cidr_blocks or allowed_security_group_ids
  #     -> exactly those sources are allowed, and NOTHING else. The VPC CIDR is
  #        never added on top. A caller who restricts, restricts.
  #
  #   both lists empty
  #     -> fall back to the VPC CIDR when allow_vpc_cidr_ingress is true (the
  #        pre-refactor behaviour, so a migrated stack does not silently lose
  #        connectivity), or to no ingress rule at all when it is false.
  #
  # The empty-result case is surfaced by check "ingress_is_reachable" below.
  ################################################################################
  has_explicit_allow_list = length(var.allowed_cidr_blocks) > 0 || length(var.allowed_security_group_ids) > 0

  ingress_cidr_blocks = (
    local.has_explicit_allow_list
    ? var.allowed_cidr_blocks
    : (var.allow_vpc_cidr_ingress ? compact([local.vpc_cidr]) : [])
  )

  sg_ingress_cidrs = local.create ? local.ingress_cidr_blocks : []
  sg_ingress_sgs   = local.create ? var.allowed_security_group_ids : []

  ##############################################################################
  # Shared instance — owned by products/shared-resources/postgres under product "shared"
  #
  # Resolved by derived name, never by CNAME. Every AWS datastore presents a
  # certificate for its OWN service domain (RDS: *.{region}.rds.amazonaws.com),
  # so a private CNAME in front of it breaks TLS hostname verification for any
  # client that validates it. Handing out the raw AWS endpoint is the only shape
  # that works with TLS on, so it is the only shape this module produces.
  ##############################################################################
  shared_identifier = (
    var.shared_identifier != ""
    ? var.shared_identifier
    : "shared-${var.environment}-${local.component}"
  )

  shared_secret_name = (
    var.shared_secret_name != ""
    ? var.shared_secret_name
    : "shared-${var.environment}-${local.component}/password"
  )

  create_replica = local.create && var.create_read_replica

  # RDS instance classes on which AWS does NOT offer Performance Insights.
  # Enabling it on one of these is accepted by `terraform plan` and rejected by
  # the CreateDBInstance API, so it is checked as a precondition below.
  performance_insights_unsupported_classes = [
    "db.t2.micro",
    "db.t2.small",
    "db.t3.micro",
    "db.t3.small",
    "db.t4g.micro",
    "db.t4g.small",
  ]

  performance_insights_classes_in_use = compact([
    var.instance_class,
    local.create_replica ? var.read_replica_instance_class : null,
  ])
}

################################################################################
# Guardrail
#
# A `check` block, not a `precondition`: an unreachable datastore is a
# misconfiguration worth shouting about, but it is not worth making the stack
# un-appliable — an operator may legitimately apply the instance first and wire
# the allow list in a second pass.
################################################################################

check "ingress_is_reachable" {
  assert {
    condition = (
      !local.create
      || length(local.sg_ingress_cidrs) > 0
      || length(local.sg_ingress_sgs) > 0
    )
    error_message = <<-EOT
      The ${module.naming.name} PostgreSQL instance has NO ingress rule: both
      allowed_cidr_blocks and allowed_security_group_ids are empty and
      allow_vpc_cidr_ingress is false, so the VPC CIDR fallback was skipped.
      Nothing can connect to the instance. Pass allowed_security_group_ids /
      allowed_cidr_blocks, or set allow_vpc_cidr_ingress = true.
    EOT
  }
}

module "naming" {
  source = "../naming"

  product     = var.product
  environment = var.environment
  component   = local.component
  extra_tags  = var.extra_tags
}

################################################################################
# Security group
#
# No egress rule is declared, matching the pre-refactor stack: an RDS instance
# does not initiate outbound connections.
################################################################################

resource "aws_security_group" "this" {
  count = local.create ? 1 : 0

  name        = "${module.naming.name}-sg"
  description = "Security group for the ${module.naming.name} RDS instance"
  vpc_id      = local.vpc_id

  tags = merge(module.naming.tags, {
    Name = "${module.naming.name}-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "cidr" {
  for_each = toset(local.sg_ingress_cidrs)

  security_group_id = aws_security_group.this[0].id
  description       = "PostgreSQL access from ${each.value}"
  ip_protocol       = "tcp"
  from_port         = var.port
  to_port           = var.port
  cidr_ipv4         = each.value

  tags = module.naming.tags
}

resource "aws_vpc_security_group_ingress_rule" "security_group" {
  for_each = toset(local.sg_ingress_sgs)

  security_group_id            = aws_security_group.this[0].id
  description                  = "PostgreSQL access from ${each.value}"
  ip_protocol                  = "tcp"
  from_port                    = var.port
  to_port                      = var.port
  referenced_security_group_id = each.value

  tags = module.naming.tags
}

################################################################################
# Subnet group
################################################################################

resource "aws_db_subnet_group" "this" {
  count = local.create ? 1 : 0

  name       = "${module.naming.name}-subnet-group"
  subnet_ids = local.subnet_ids

  tags = merge(module.naming.tags, {
    Name = "${module.naming.name}-subnet-group"
  })
}

################################################################################
# Credentials
#
# Secret path is "{product}-{environment}-postgres/password".
################################################################################

################################################################################
# THE CHARACTER SET IS DELIBERATELY NARROW. DO NOT WIDEN IT.
#
# override_special is restricted to the RFC 3986 §2.3 "unreserved" set — the
# four characters `-` `_` `.` `~` — because consumers interpolate this password
# RAW into a connection URL, with no percent-encoding anywhere in the path.
#
# This is not hypothetical. Two concrete consumers, both in this fleet:
#
#   * br-sfn states the rule in words in its own chart README:
#     "Postgres passwords must be URL-safe (no @ : / ? # %)". It has to, because
#     its baked-flavour migration Jobs build the DSN by string interpolation:
#       -database "postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}?sslmode=..."
#     (charts/br-sfn/templates/_helpers.tpl:604).
#   * plugin-br-pix-switch reaches every datastore through a URL — DATABASE_URL,
#     MONGO_URL, VALKEY_URL, RABBITMQ_URI.
#
# The previous set was "!#$%^&*()-_=+[]{}<>:?" and four of its members break a
# URL, each in a different and separately confusing way:
#     #  truncates the DSN at the fragment      -> silently drops everything after it
#     %  opens an invalid percent-escape        -> parse error, or a mangled byte
#     ?  starts the query string                -> the rest becomes bogus params
#     :  splits userinfo                        -> password read as host:port
# Over 16 characters drawn from ~20 symbols, hitting at least one was the
# LIKELY outcome, not the edge case — i.e. an intermittent failure that
# reproduces on roughly every other rebuild and points at nothing.
#
# The entropy given up by dropping 16 symbols is bought back with length, which
# is free here and costs no compatibility. 32 characters over the resulting
# 66-symbol alphabet (26+26+10+4) is ~193 bits, comfortably above the ~104 bits
# the old 16-character password carried.
#
# Engine limits checked before narrowing (RDS master password):
#   length     8-128  -> 32 is inside
#   forbidden  / " @ and space, plus ' on some engines
# `-_.~` collides with none of them, so this set is legal on every RDS engine
# this module can be pointed at, not just PostgreSQL.
#
# The min_* floors guarantee all four character classes are present, which
# makes the generated value deterministic in SHAPE (never all-alphanumeric,
# never a single class) instead of merely probable.
################################################################################

resource "random_password" "master" {
  count = local.create ? 1 : 0

  length           = 32
  special          = true
  override_special = "-_.~"

  min_lower   = 2
  min_upper   = 2
  min_numeric = 2
  min_special = 2
}

resource "aws_secretsmanager_secret" "this" {
  count = local.create ? 1 : 0

  name        = "${module.naming.name}/password"
  description = "Master credentials for the ${module.naming.name} RDS instance"

  tags = merge(module.naming.tags, {
    Name = "${module.naming.name}/password"
  })

  lifecycle {
    # The RDS identifier and the IAM monitoring role name both derive from
    # module.naming.name, so guard the AWS limits once, here, at plan time.
    precondition {
      condition     = length(module.naming.name) <= 63
      error_message = "The derived name '${module.naming.name}' exceeds the 63 character RDS DB identifier limit. Shorten var.product."
    }

    precondition {
      condition     = can(regex("^[a-z][a-z0-9-]*[a-z0-9]$", module.naming.name))
      error_message = "The derived name '${module.naming.name}' is not a valid RDS DB identifier (lowercase letters, digits and hyphens; must start with a letter)."
    }

    # performance_insights_enabled defaults to true on purpose: production must
    # not lose query-level observability because nobody remembered to switch it
    # on. The cost is that the smallest burstable classes - which is exactly what
    # the dev tfvars use - do not support the feature, and AWS only says so ~5
    # minutes into the apply. Fail at plan time instead.
    precondition {
      condition = (
        !var.performance_insights_enabled
        || length(setintersection(
          toset(local.performance_insights_classes_in_use),
          toset(local.performance_insights_unsupported_classes),
        )) == 0
      )
      error_message = "performance_insights_enabled = true is not supported on ${join(", ", local.performance_insights_unsupported_classes)}. In use here: ${join(", ", local.performance_insights_classes_in_use)}. Either move to db.t4g.medium or larger, or set performance_insights_enabled = false (dev/stg only - production keeps it on)."
    }
  }
}

resource "aws_secretsmanager_secret_version" "this" {
  count = local.create ? 1 : 0

  secret_id = aws_secretsmanager_secret.this[0].id
  secret_string = jsonencode({
    username = var.username
    password = random_password.master[0].result
    engine   = var.engine
    host     = module.db[0].db_instance_address
    port     = var.port
    dbname   = var.database_name
  })
}

################################################################################
# Primary instance
################################################################################

module "db" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 6.0"

  count = local.create ? 1 : 0

  identifier = module.naming.name

  # Engine config
  engine               = var.engine
  engine_version       = var.engine_version
  family               = var.family
  major_engine_version = var.major_engine_version
  instance_class       = var.instance_class

  # Storage config
  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage

  # Database config
  db_name  = var.database_name
  username = var.username
  port     = var.port
  password = random_password.master[0].result

  # Not supported with replicas
  manage_master_user_password = false

  # Network config
  multi_az               = var.multi_az
  db_subnet_group_name   = aws_db_subnet_group.this[0].name
  vpc_security_group_ids = [aws_security_group.this[0].id]

  # Parameter group. use_name_prefix stays at its default (true) so a family
  # change can create the replacement group before destroying the old one; the
  # prefix itself is naming-derived, which is what prevents cross-env collision.
  parameter_group_name = module.naming.name
  parameters           = var.parameters

  # Maintenance and backup config
  maintenance_window              = var.maintenance_window
  backup_window                   = var.backup_window
  enabled_cloudwatch_logs_exports = var.enabled_cloudwatch_logs_exports
  create_cloudwatch_log_group     = var.create_cloudwatch_log_group
  backup_retention_period         = var.backup_retention_period
  skip_final_snapshot             = var.skip_final_snapshot
  deletion_protection             = var.deletion_protection

  # Monitoring config
  performance_insights_enabled          = var.performance_insights_enabled
  performance_insights_retention_period = var.performance_insights_retention_period
  create_monitoring_role                = var.create_monitoring_role
  monitoring_interval                   = var.monitoring_interval
  monitoring_role_name                  = "${module.naming.name}-monitoring-role"
  monitoring_role_use_name_prefix       = false

  # Authentication config
  iam_database_authentication_enabled = true

  tags = merge(module.naming.tags, {
    Name = module.naming.name
  })
}

################################################################################
# Read replica
################################################################################

module "db_replica" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 6.0"

  count = local.create_replica ? 1 : 0

  identifier = "${module.naming.name}-replica"

  # Source config
  replicate_source_db = module.db[0].db_instance_arn

  # Engine config
  engine               = var.engine
  engine_version       = var.engine_version
  family               = var.family
  major_engine_version = var.major_engine_version

  # Instance config
  instance_class = var.read_replica_instance_class
  multi_az       = var.read_replica_multi_az

  # A replica inherits the master credentials from its source; letting the
  # upstream module default manage_master_user_password to true would make RDS
  # reject the create call.
  manage_master_user_password = false

  # Network config
  db_subnet_group_name   = aws_db_subnet_group.this[0].name
  vpc_security_group_ids = [aws_security_group.this[0].id]

  # Maintenance and backup config
  backup_retention_period = 0 # Primary handles backups
  skip_final_snapshot     = true

  parameter_group_name = "${module.naming.name}-replica"
  parameters           = var.parameters

  # Monitoring config
  performance_insights_enabled          = var.performance_insights_enabled
  performance_insights_retention_period = var.performance_insights_retention_period
  create_monitoring_role                = var.create_monitoring_role
  monitoring_interval                   = var.monitoring_interval
  monitoring_role_name                  = "${module.naming.name}-replica-monitoring-role"
  monitoring_role_use_name_prefix       = false

  tags = merge(module.naming.tags, {
    Name = "${module.naming.name}-replica"
    Type = "read-replica"
  })
}
