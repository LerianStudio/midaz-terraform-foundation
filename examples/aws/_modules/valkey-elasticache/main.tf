################################################################################
# valkey-elasticache
#
# Thin wrapper over terraform-aws-modules/elasticache/aws for the Lerian Valkey
# datastore. Migrated from the pre-v2 examples/aws/valkey stack (removed in v2)
# with four changes:
#
#   1. every name comes from the naming module ({product}-{environment}-valkey),
#      so replication_group_id / subnet_group_name / parameter_group_name no
#      longer collide when dev, stg and prd share one AWS account;
#   2. BUG FIX - the auth token secret was named "{name}-auth/test", with a
#      hardcoded "/test" suffix (was examples/aws/valkey/credentials.tf:14). It is
#      now "{product}-{environment}-valkey/auth-token";
#   3. the standalone aws_security_group the old stack created was never
#      attached to anything - the upstream module builds and attaches its own.
#      Ingress is now expressed through security_group_rules, and
#      output security_group_id returns the group actually in the data path;
#   4. mode = "shared" makes the module create nothing and resolve the group
#      that products/shared-resources/valkey already created.
#
# ElastiCache limits worth knowing: replication_group_id accepts at most 40
# characters and no underscores. The derived name is
# {product}-{environment}-valkey, so the worst case is 24 (the naming module's
# product ceiling) + 1 + 3 + 1 + 6 = 35 characters - inside the limit. The
# naming module's product/component regexes already reject underscores. Both
# invariants are re-checked as plan-time preconditions below rather than trusted.
################################################################################

locals {
  component = "valkey"
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

  # Both maps below must carry the same attribute set, otherwise merge() cannot
  # unify the object types.
  cidr_rules = {
    for cidr in local.ingress_cidr_blocks :
    "ingress_cidr_${replace(replace(cidr, ".", "_"), "/", "_")}" => {
      description                  = "Valkey access from ${cidr}"
      cidr_ipv4                    = cidr
      referenced_security_group_id = null
      ip_protocol                  = "tcp"
      from_port                    = var.port
      to_port                      = var.port
    }
  }

  security_group_rules = {
    for sg in var.allowed_security_group_ids :
    "ingress_sg_${sg}" => {
      description                  = "Valkey access from ${sg}"
      cidr_ipv4                    = null
      referenced_security_group_id = sg
      ip_protocol                  = "tcp"
      from_port                    = var.port
      to_port                      = var.port
    }
  }

  ingress_rules = merge(local.cidr_rules, local.security_group_rules)

  ##############################################################################
  # Shared group — owned by products/shared-resources/valkey under product "shared"
  #
  # Resolved by derived name, never by CNAME. The ElastiCache in-transit
  # certificate is issued for *.{cluster}.{region}.cache.amazonaws.com, so a
  # private CNAME in front of the primary endpoint fails TLS hostname
  # verification — and this module ships transit_encryption_enabled = true in
  # every environment, which made the CNAME the actively broken option rather
  # than merely a redundant one.
  ##############################################################################
  shared_identifier = (
    var.shared_identifier != ""
    ? var.shared_identifier
    : "shared-${var.environment}-${local.component}"
  )

  shared_secret_name = (
    var.shared_secret_name != ""
    ? var.shared_secret_name
    : "shared-${var.environment}-${local.component}/auth-token"
  )
}

module "naming" {
  source = "../naming"

  product     = var.product
  environment = var.environment
  component   = local.component
  extra_tags  = var.extra_tags
}

################################################################################
# Guardrail
#
# A `check` block, not a `precondition`: an unreachable datastore is a
# misconfiguration worth shouting about, but it is not worth making the stack
# un-appliable — an operator may legitimately apply the group first and wire the
# allow list in a second pass.
################################################################################

check "ingress_is_reachable" {
  assert {
    condition = (
      !local.create
      || length(local.ingress_rules) > 0
    )
    error_message = <<-EOT
      The ${module.naming.name} Valkey replication group has NO ingress rule: both
      allowed_cidr_blocks and allowed_security_group_ids are empty and
      allow_vpc_cidr_ingress is false, so the VPC CIDR fallback was skipped.
      Nothing can connect to the group. Pass allowed_security_group_ids /
      allowed_cidr_blocks, or set allow_vpc_cidr_ingress = true.
    EOT
  }
}

################################################################################
# Credentials
#
# The token is always generated and stored so external-secrets has a stable
# path to read; var.auth_token_enabled decides whether ElastiCache enforces it.
################################################################################

resource "random_password" "auth" {
  count = local.create ? 1 : 0

  length           = 32
  special          = true
  override_special = "!#$%&'()*+,-.:<=>?[]^_`{|}~"
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
  min_special      = 2
}

resource "aws_secretsmanager_secret" "auth" {
  count = local.create ? 1 : 0

  name        = "${module.naming.name}/auth-token"
  description = "Auth token for the ${module.naming.name} Valkey replication group"

  tags = merge(module.naming.tags, {
    Name = "${module.naming.name}/auth-token"
  })

  lifecycle {
    # replication_group_id, subnet_group_name and parameter_group_name all
    # derive from module.naming.name, so guard the ElastiCache limits once,
    # here, at plan time.
    precondition {
      condition     = length(module.naming.name) <= 40
      error_message = "The derived name '${module.naming.name}' exceeds the 40 character ElastiCache replication_group_id limit. Shorten var.product."
    }

    precondition {
      condition     = can(regex("^[a-z][a-z0-9-]*[a-z0-9]$", module.naming.name))
      error_message = "The derived name '${module.naming.name}' is not a valid ElastiCache replication_group_id (lowercase letters, digits and hyphens only; no underscores; must start with a letter)."
    }

    precondition {
      condition     = !var.auth_token_enabled || var.transit_encryption_enabled
      error_message = "auth_token_enabled requires transit_encryption_enabled = true; ElastiCache rejects an auth token without in-transit encryption."
    }
  }
}

resource "aws_secretsmanager_secret_version" "auth" {
  count = local.create ? 1 : 0

  secret_id     = aws_secretsmanager_secret.auth[0].id
  secret_string = random_password.auth[0].result
}

################################################################################
# Replication group
################################################################################

module "valkey" {
  source  = "terraform-aws-modules/elasticache/aws"
  version = "~> 1.6.0"

  count = local.create ? 1 : 0

  replication_group_id = module.naming.name

  # Engine configuration
  engine         = "valkey"
  engine_version = var.engine_version
  node_type      = var.node_type
  port           = var.port

  # Availability
  num_cache_clusters         = var.num_cache_clusters
  automatic_failover_enabled = var.automatic_failover_enabled
  multi_az_enabled           = var.multi_az_enabled
  snapshot_retention_limit   = var.snapshot_retention_limit

  # Network configuration. The module owns the security group; security_group_name
  # is naming-derived and security_group_use_name_prefix keeps its default (true),
  # so the group can be replaced without a name conflict.
  vpc_id               = local.vpc_id
  security_group_name  = module.naming.name
  security_group_rules = local.ingress_rules

  # Subnet group
  subnet_group_name        = module.naming.name
  subnet_group_description = "Subnet group for the ${module.naming.name} Valkey replication group"
  subnet_ids               = local.subnet_ids

  # Parameter group
  create_parameter_group      = true
  parameter_group_name        = module.naming.name
  parameter_group_family      = var.parameter_group_family
  parameter_group_description = "Parameter group for the ${module.naming.name} Valkey replication group"
  parameters                  = var.parameters

  # Security
  at_rest_encryption_enabled = var.at_rest_encryption_enabled
  transit_encryption_enabled = var.transit_encryption_enabled
  transit_encryption_mode    = var.transit_encryption_mode
  auth_token                 = var.auth_token_enabled ? random_password.auth[0].result : null

  # Maintenance
  maintenance_window = var.maintenance_window
  apply_immediately  = var.apply_immediately

  tags = merge(module.naming.tags, {
    Name = module.naming.name
  })
}
