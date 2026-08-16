################################################################################
# mongodb-documentdb
#
# Amazon DocumentDB (MongoDB compatible) cluster for a Lerian product.
# Migrated from the pre-v2 examples/aws/documentdb stack (removed in v2), which
# existed in three identical copies
# (documentdb, documentdb-plugin-fee, documentdb-plugin-crm). This single module
# replaces all three: the product name is now an input, so the plugins simply
# instantiate it with a different `product`.
#
# Helm wiring: `endpoint` is the host to put in MONGO_*_HOST. It is the raw AWS
# writer endpoint in both modes — see data.tf for why there is no CNAME.
#
# mode = "dedicated" -> creates the cluster, SG, secret and CMK.
# mode = "shared"    -> creates nothing; resolves the shared cluster owned by
#                       products/shared-resources/documentdb (product = "shared") by its
#                       derived identifier, plus its Secrets Manager entry.
################################################################################

module "naming" {
  source = "../naming"

  product     = var.product
  environment = var.environment
  component   = local.naming_component
  extra_tags  = var.extra_tags
}

locals {
  # Naming component: the AWS resource suffix. "docdb" because that is the AWS
  # service name; the applications and Helm charts speak "mongodb", but that
  # label now only appears in the chart variable names, not in any hostname —
  # the host handed to Helm is the raw *.docdb.amazonaws.com endpoint.
  naming_component = "docdb"

  create = var.mode == "dedicated"

  vpc_name = var.vpc_name != "" ? var.vpc_name : "lerian-${var.environment}-vpc"

  vpc_cidr = try(data.aws_vpc.selected[0].cidr_block, "")

  ################################################################################
  # Ingress — THE single rule, identical in all five datastore modules
  #
  #   any entry in allowed_cidr_blocks or allowed_security_group_ids
  #     -> exactly those sources are allowed, and NOTHING else. The VPC CIDR is
  #        never added on top. A caller who restricts, restricts.
  #
  #   both lists empty
  #     -> fall back to the VPC CIDR when allow_vpc_cidr_ingress is true (the
  #        pre-v2 examples/aws/documentdb behaviour), or to no ingress rule at all
  #        when it is false.
  #
  # This REPLACES the previous behaviour, where allow_vpc_cidr_ingress opened the
  # whole VPC CIDR — public subnets included — even when a restricted allow list
  # had been supplied. A caller who passed a tight list believed they had
  # restricted the cluster and had not.
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

  # DocumentDB instance classes. db.t3.medium is the SMALLEST class the service
  # offers: the RDS-style micro/small sizes simply do not exist for DocumentDB and
  # AWS rejects them at CreateDBInstance, not at plan. The dev tfvars sit exactly
  # on this floor, so guard it at plan time.
  unsupported_instance_classes = [
    "db.t2.micro",
    "db.t2.small",
    "db.t3.micro",
    "db.t3.small",
    "db.t4g.micro",
    "db.t4g.small",
  ]

  ##############################################################################
  # Shared cluster — owned by products/shared-resources/documentdb under product "shared"
  #
  # The identifier below is the ONLY input to the shared-cluster resolution; the
  # data source that consumes it, and the reason it is data "aws_rds_cluster"
  # rather than a docdb-specific one, are documented in data.tf.
  #
  # There is no CNAME: the DocumentDB server certificate is issued for
  # *.docdb.amazonaws.com, so a private alias in front of the writer endpoint
  # fails hostname validation on any driver that checks it — which is every
  # modern driver by default.
  ##############################################################################
  shared_identifier = (
    var.shared_identifier != ""
    ? var.shared_identifier
    : "shared-${var.environment}-${local.naming_component}"
  )

  # Secret of the shared cluster: shared-resources/documentdb creates it as
  # "{module.naming.name}/password" with product = "shared".
  shared_secret_name = (
    var.shared_secret_name != ""
    ? var.shared_secret_name
    : "shared-${var.environment}-${local.naming_component}/password"
  )
}

# Random master password, stored in Secrets Manager and handed to the cluster.
#
################################################################################
# THE CHARACTER SET IS DELIBERATELY NARROW. DO NOT WIDEN IT.
#
# override_special is restricted to the RFC 3986 §2.3 "unreserved" set — the
# four characters `-` `_` `.` `~` — because consumers interpolate this password
# RAW into a MongoDB connection URI, with no percent-encoding.
#
# This is not hypothetical. Two concrete consumers, both in this fleet:
#
#   * plugin-br-bank-transfer assembles MONGO_URI by string interpolation on the
#     DEFAULT install path, where escaping is structurally impossible: the
#     password arrives through Kubernetes $(VAR) expansion at container start,
#     so no Helm function can touch it —
#       mongodb://bank_transfer:$(MONGO_PASSWORD)@{host}:27017/?authSource=admin
#     (charts/plugin-br-bank-transfer/templates/_helpers.tpl:196-199).
#     Its external-Mongo branch DOES pipe through `urlquery`
#     (templates/secrets.yaml:56) — so the escaping is inconsistent between the
#     two paths, and only the unescaped one is the default.
#   * plugin-br-pix-switch reaches every datastore through a URL — DATABASE_URL,
#     MONGO_URL, VALKEY_URL, RABBITMQ_URI.
#
# The previous set was "!#$^&*()-_=+[]{}<>?" and three of its members break a
# URI, each in a different and separately confusing way:
#     #  truncates the URI at the fragment      -> authSource silently dropped
#     $  collides with $(VAR) shell expansion   -> see the helper above
#     ?  starts the query string                -> authSource duplicated/lost
# Over 16 characters drawn from ~19 symbols, hitting at least one was the
# LIKELY outcome, not the edge case — i.e. an intermittent auth failure that
# reproduces on roughly every other rebuild and points at nothing.
#
# The entropy given up by dropping 15 symbols is bought back with length, which
# is free here and costs no compatibility. 32 characters over the resulting
# 66-symbol alphabet (26+26+10+4) is ~193 bits, comfortably above the ~102 bits
# the old 16-character password carried.
#
# Engine limits checked before narrowing (DocumentDB master password — its own
# limits, NOT the RDS ones, even though this module reads back through
# data "aws_rds_cluster"):
#   length     8-100  -> 32 is inside; note the ceiling is 100, not RDS's 128
#   forbidden  / " @
# `-_.~` collides with none of them.
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

resource "aws_secretsmanager_secret" "docdb_password" {
  count = local.create ? 1 : 0

  name = "${module.naming.name}/password"
  tags = module.naming.tags
}

resource "aws_secretsmanager_secret_version" "docdb_password" {
  count = local.create ? 1 : 0

  secret_id     = aws_secretsmanager_secret.docdb_password[0].id
  secret_string = random_password.master[0].result
}

# DocumentDB subnet group
resource "aws_docdb_subnet_group" "main" {
  count = local.create ? 1 : 0

  name       = "${module.naming.name}-subnet-group"
  subnet_ids = data.aws_subnets.selected[0].ids

  tags = merge(module.naming.tags, { Name = "${module.naming.name}-subnet-group" })
}

################################################################################
# Security group
#
# Ingress rules are standalone resources (not inline blocks) so that callers can
# add their own allowed SGs/CIDRs through the module contract. No egress rule is
# declared, which matches the pre-v2 stack.
################################################################################

resource "aws_security_group" "docdb" {
  count = local.create ? 1 : 0

  name        = "${module.naming.name}-sg"
  description = "Allow traffic to DocumentDB cluster ${module.naming.name}"
  vpc_id      = data.aws_vpc.selected[0].id

  tags = merge(module.naming.tags, { Name = "${module.naming.name}-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "allowed_security_groups" {
  for_each = toset(local.sg_ingress_sgs)

  security_group_id            = aws_security_group.docdb[0].id
  description                  = "DocumentDB access from ${each.value}"
  referenced_security_group_id = each.value
  from_port                    = var.port
  to_port                      = var.port
  ip_protocol                  = "tcp"

  tags = module.naming.tags
}

resource "aws_vpc_security_group_ingress_rule" "allowed_cidr_blocks" {
  for_each = toset(local.sg_ingress_cidrs)

  security_group_id = aws_security_group.docdb[0].id
  description       = "DocumentDB access from ${each.value}"
  cidr_ipv4         = each.value
  from_port         = var.port
  to_port           = var.port
  ip_protocol       = "tcp"

  tags = module.naming.tags
}

################################################################################
# Guardrail
#
# A `check` block, not a `precondition`: an unreachable datastore is a
# misconfiguration worth shouting about, but it is not worth making the stack
# un-appliable — an operator may legitimately apply the cluster first and wire the
# allow list in a second pass.
################################################################################

check "ingress_is_reachable" {
  assert {
    condition = (
      !local.create
      || length(local.sg_ingress_cidrs) > 0
      || length(local.sg_ingress_sgs) > 0
    )
    error_message = <<-EOT
      The ${module.naming.name} DocumentDB cluster has NO ingress rule: both
      allowed_cidr_blocks and allowed_security_group_ids are empty and
      allow_vpc_cidr_ingress is false, so the VPC CIDR fallback was skipped.
      Nothing can connect to the cluster. Pass allowed_security_group_ids /
      allowed_cidr_blocks, or set allow_vpc_cidr_ingress = true.
    EOT
  }
}

################################################################################
# Cluster
################################################################################

resource "aws_docdb_cluster_parameter_group" "main" {
  count = local.create ? 1 : 0

  family      = var.parameter_group_family
  name        = "${module.naming.name}-param-group"
  description = "DocumentDB cluster parameter group for ${module.naming.name}"

  parameter {
    name  = "tls"
    value = var.documentdb_tls
  }

  tags = merge(module.naming.tags, { Name = "${module.naming.name}-param-group" })
}

resource "aws_docdb_cluster" "main" {
  count = local.create ? 1 : 0

  cluster_identifier              = module.naming.name
  engine                          = "docdb"
  engine_version                  = var.engine_version
  port                            = var.port
  master_username                 = var.master_username
  master_password                 = aws_secretsmanager_secret_version.docdb_password[0].secret_string
  db_subnet_group_name            = aws_docdb_subnet_group.main[0].name
  vpc_security_group_ids          = [aws_security_group.docdb[0].id]
  db_cluster_parameter_group_name = aws_docdb_cluster_parameter_group.main[0].name
  backup_retention_period         = var.backup_retention_period
  preferred_backup_window         = var.preferred_backup_window
  enabled_cloudwatch_logs_exports = var.enabled_cloudwatch_logs_exports
  storage_encrypted               = true
  kms_key_id                      = module.docdb_kms_key[0].key_arn
  deletion_protection             = var.deletion_protection
  apply_immediately               = var.apply_immediately
  skip_final_snapshot             = var.skip_final_snapshot
  final_snapshot_identifier       = var.skip_final_snapshot ? null : "${module.naming.name}-final-snapshot"

  tags = merge(module.naming.tags, { Name = module.naming.name })
}

resource "aws_docdb_cluster_instance" "main" {
  count = local.create ? var.instances_count : 0

  identifier         = "${module.naming.name}-instance-${count.index}"
  cluster_identifier = aws_docdb_cluster.main[0].id
  instance_class     = var.instance_class
  apply_immediately  = var.apply_immediately

  tags = merge(module.naming.tags, { Name = "${module.naming.name}-instance-${count.index}" })

  lifecycle {
    # DocumentDB's smallest class is db.t3.medium. Passing an RDS micro/small size
    # plans cleanly and then fails the CreateDBInstance call minutes into the
    # apply, which is the same footgun postgres-rds guards for Performance
    # Insights. Catch it at plan time.
    precondition {
      condition     = !contains(local.unsupported_instance_classes, var.instance_class)
      error_message = "instance_class '${var.instance_class}' does not exist for DocumentDB. Unsupported: ${join(", ", local.unsupported_instance_classes)}. db.t3.medium is the smallest class DocumentDB offers - use it, or db.t4g.medium / db.r6g.large and up."
    }
  }
}
