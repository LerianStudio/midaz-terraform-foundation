################################################################################
# rabbitmq-amazonmq
#
# Amazon MQ for RabbitMQ broker for a Lerian product.
# Migrated from the pre-v2 examples/aws/amazonmq stack (removed in v2),
# preserving the SINGLE_INSTANCE /
# CLUSTER_MULTI_AZ support, the one-subnet-per-AZ spreading logic and the four
# lifecycle preconditions that catch the AWS-side constraints at plan time.
#
# TWO DIFFERENT "MODES" LIVE IN THIS MODULE - do not conflate them:
#   var.mode                   -> Lerian sharing contract: dedicated | shared
#   var.broker_deployment_mode -> AmazonMQ topology: SINGLE_INSTANCE | CLUSTER_MULTI_AZ
# The pre-v2 stack called the second one `deployment_mode` and derived
# `local.name = "${var.name}-${local.mode_suffix}"` from it, which reads as if it
# were the sharing mode. It is not.
#
# Helm wiring: `endpoint` is the host for RABBITMQ_HOST, `port` is 5671, and
# every component talking to AmazonMQ must set RABBITMQ_URI: "amqps" (see the
# repository README) because AmazonMQ only speaks AMQP over TLS. `endpoint` is
# the raw AWS broker host in both modes: the broker certificate is issued for
# *.mq.{region}.on.aws, so an AMQPS client that validates the hostname — and it
# always speaks AMQPS here — cannot go through a private alias.
################################################################################

module "naming" {
  source = "../naming"

  product     = var.product
  environment = var.environment
  component   = local.naming_component
  extra_tags  = var.extra_tags
}

locals {
  naming_component = "rabbitmq"

  create = var.mode == "dedicated"

  vpc_name = var.vpc_name != "" ? var.vpc_name : "lerian-${var.environment}-vpc"

  # AmazonMQ topology, kept separate from var.mode on purpose.
  is_cluster_deployment    = var.broker_deployment_mode == "CLUSTER_MULTI_AZ"
  broker_deployment_suffix = local.is_cluster_deployment ? "cluster" : "single"

  # Only the broker itself carries the topology suffix, so that a side-by-side
  # single -> cluster migration is possible (docs/UPGRADE-GUIDE.md). The secret
  # and the security group stay on the plain naming.name, which is what makes
  # the shared SECRET resolvable regardless of the shared broker's topology —
  # the shared BROKER is the one thing that has to know it, see
  # local.shared_broker_name below and the note in data.tf.
  broker_name = var.append_deployment_suffix ? "${module.naming.name}-${local.broker_deployment_suffix}" : module.naming.name

  # Host instance types AmazonMQ offers for the RabbitMQ engine, per
  #   aws mq describe-broker-instance-options --engine-type RABBITMQ
  #
  # Two things this list makes explicit, both of which the pre-v2 stack got wrong:
  #   1. mq.t2.* / mq.t3.* are ActiveMQ-ONLY. RabbitMQ rejects them in EVERY
  #      deployment mode - not just under CLUSTER_MULTI_AZ. The old
  #      "mq.t3.micro works for SINGLE_INSTANCE" assumption fails the
  #      CreateBroker call outright.
  #   2. Every type below supports BOTH SINGLE_INSTANCE and CLUSTER_MULTI_AZ.
  #      There is no RabbitMQ type that is single-only, so the deployment mode
  #      does not narrow this list at all.
  #
  # The precondition validates by FAMILY prefix, not against the exact list:
  # AWS adds sizes inside an existing family far more often than it adds
  # families, and a closed list would false-reject a brand new (valid) size at
  # plan time. The exact list below is carried only to make the error message
  # actionable. Revisit supported_instance_families when AWS ships a new
  # RabbitMQ family - a further Graviton generation, say.
  supported_instance_families = ["mq.m5.", "mq.m7g."]

  supported_instance_types = [
    "mq.m5.large", "mq.m5.xlarge", "mq.m5.2xlarge", "mq.m5.4xlarge",
    "mq.m7g.medium", "mq.m7g.large", "mq.m7g.xlarge", "mq.m7g.2xlarge",
    "mq.m7g.4xlarge", "mq.m7g.8xlarge", "mq.m7g.12xlarge", "mq.m7g.16xlarge",
  ]

  host_instance_type_supported = anytrue([
    for family in local.supported_instance_families :
    startswith(var.host_instance_type, family)
  ])

  # Group subnets by availability zone and pick one subnet per AZ.
  # This ensures each selected subnet is in a different AZ for HA.
  subnets_by_az = {
    for id, subnet in data.aws_subnet.selected :
    subnet.availability_zone => id...
  }
  distinct_az_count = length(local.subnets_by_az)

  # Select one subnet per AZ (up to 3 - the RabbitMQ cluster maximum).
  cluster_subnet_ids = slice(
    [for az, ids in local.subnets_by_az : ids[0]],
    0,
    min(local.distinct_az_count, 3)
  )

  # Subnet selection logic:
  # - SINGLE_INSTANCE: 1 subnet
  # - CLUSTER_MULTI_AZ: 2-3 subnets in different AZs
  # Note: using try() to avoid index-out-of-bounds before preconditions run.
  subnet_ids = !local.create ? [] : (
    local.is_cluster_deployment ? local.cluster_subnet_ids : [try(data.aws_subnets.selected[0].ids[0], null)]
  )

  ################################################################################
  # Ingress — THE single rule, identical in all five datastore modules
  #
  #   any entry in allowed_cidr_blocks or allowed_security_group_ids
  #     -> exactly those sources are allowed, and NOTHING else. The VPC CIDR is
  #        never added on top. A caller who restricts, restricts.
  #
  #   both lists empty
  #     -> fall back to the VPC CIDR when allow_vpc_cidr_ingress is true (the
  #        pre-v2 examples/aws/amazonmq behaviour), or to no ingress rule at all
  #        when it is false.
  #
  # This REPLACES the previous behaviour, where allow_vpc_cidr_ingress opened the
  # whole VPC CIDR — public subnets included — even when a restricted allow list
  # had been supplied. A caller who passed a tight list believed they had
  # restricted the broker and had not.
  #
  # Scoped by PORT, like the other four modules. The rules used to be written with
  # ip_protocol = "-1", which is every protocol on every port; AmazonMQ for
  # RabbitMQ listens on exactly two:
  #
  #   var.port          5671  AMQPS. The only AMQP listener - there is no
  #                           plaintext 5672, which is why RABBITMQ_URI is "amqps".
  #   var.console_port   443  the RabbitMQ management console / management HTTP
  #                           API, over HTTPS. Toggled by enable_console_ingress.
  ################################################################################
  vpc_cidr = try(data.aws_vpc.selected[0].cidr_block, "")

  has_explicit_allow_list = length(var.allowed_cidr_blocks) > 0 || length(var.allowed_security_group_ids) > 0

  ingress_cidr_blocks = (
    local.has_explicit_allow_list
    ? var.allowed_cidr_blocks
    : (var.allow_vpc_cidr_ingress ? compact([local.vpc_cidr]) : [])
  )

  sg_ingress_cidrs = local.create ? local.ingress_cidr_blocks : []
  sg_ingress_sgs   = local.create ? var.allowed_security_group_ids : []

  # Static, so the rule map keys stay known at plan time. The port the broker
  # actually reports is local.amqp_port below, which is only known after apply.
  ingress_ports = distinct(concat(
    [var.port],
    var.enable_console_ingress ? [var.console_port] : [],
  ))

  # AmazonMQ returns endpoints already carrying the scheme and the port, e.g.
  # amqps://b-1234abcd-....mq.us-east-2.on.aws:5671
  #
  # Both collections are built with a `for` over the resource rather than an index
  # so that count = 0 yields [] instead of an index error.
  # The same `for` shape is used over the data source, so shared mode goes
  # through exactly the same scheme/port parsing as dedicated mode below.
  broker_endpoints = (
    local.create
    ? flatten([for b in aws_mq_broker.main : b.instances[*].endpoints])
    : flatten([for b in data.aws_mq_broker.shared : b.instances[*].endpoints])
  )
  broker_console_urls = (
    local.create
    ? flatten([for b in aws_mq_broker.main : b.instances[*].console_url])
    : flatten([for b in data.aws_mq_broker.shared : b.instances[*].console_url])
  )

  amqp_endpoint_raw = try(local.broker_endpoints[0], null)
  broker_host       = try(regex("^[a-z]+://(?P<host>[^:/]+)", local.amqp_endpoint_raw).host, null)

  # AMQPS is the only AMQP listener AmazonMQ exposes for RabbitMQ.
  default_amqp_port = var.port
  amqp_port         = try(tonumber(regex(":(?P<port>[0-9]+)$", local.amqp_endpoint_raw).port), local.default_amqp_port)

  ##############################################################################
  # Shared broker — owned by products/shared-resources/rabbitmq under product "shared"
  #
  # THE ONE PLACE the shared broker name is built. The -single / -cluster suffix
  # cannot be discovered (no list data source for MQ), so it is declared here;
  # data.tf documents the constraint in full. Default is the -single shape,
  # matching the shared-resources/rabbitmq dev tfvars and its module default; stg/prd ship
  # CLUSTER_MULTI_AZ, so a consumer of the shared tier there passes
  # shared_broker_name = "shared-{env}-rabbitmq-cluster".
  ##############################################################################
  shared_broker_name = (
    var.shared_broker_name != ""
    ? var.shared_broker_name
    : "shared-${var.environment}-${local.naming_component}-single"
  )

  # Secret of the shared broker: shared-resources/rabbitmq creates it as
  # "{module.naming.name}/password" with product = "shared". No topology suffix,
  # so it resolves whether the shared broker is single or cluster.
  shared_secret_name = (
    var.shared_secret_name != ""
    ? var.shared_secret_name
    : "shared-${var.environment}-${local.naming_component}/password"
  )
}

# Random admin password, stored in Secrets Manager and handed to the broker.
#
################################################################################
# THE CHARACTER SET IS DELIBERATELY NARROW. DO NOT WIDEN IT.
#
# override_special is restricted to the RFC 3986 §2.3 "unreserved" set — the
# four characters `-` `_` `.` `~` — because this password is ALWAYS consumed as
# part of a URL. There is no non-URL consumer: the AMQP contract in this fleet
# is a connection string, not a host/user/password triple.
#
#   * br-sfn's correios rail takes correios.secrets.RABBITMQ_URL, which is a URL
#     by construction — "amqps://<user>:<password>@<endpoint>:5671/". The chart
#     states the rule in words for its Postgres sibling ("passwords must be
#     URL-safe (no @ : / ? # %)") and it applies verbatim here.
#   * plugin-br-pix-switch consumes RABBITMQ_URI.
#   * plugin-br-bank-transfer builds "amqp://bank_transfer:$(RABBITMQ_PASSWORD)@..."
#     (charts/plugin-br-bank-transfer/templates/configmap.yaml:168) via
#     Kubernetes $(VAR) expansion — escaping is structurally impossible there.
#
# The previous set was "!#$%^&*()-_+{}<>?" and three of its members break a URL,
# each in a different and separately confusing way:
#     #  truncates the URL at the fragment      -> vhost silently dropped
#     %  opens an invalid percent-escape        -> parse error, or a mangled byte
#     ?  starts the query string                -> the rest becomes bogus params
# Over 16 characters drawn from ~17 symbols, hitting at least one was the
# LIKELY outcome, not the edge case — i.e. an intermittent connection failure
# that reproduces on roughly every other rebuild and points at nothing.
#
# The entropy given up by dropping 13 symbols is bought back with length, which
# is free here and costs no compatibility. 32 characters over the resulting
# 66-symbol alphabet (26+26+10+4) is ~193 bits, comfortably above the ~101 bits
# the old 16-character password carried.
#
# Engine limits checked before narrowing (AmazonMQ CreateBroker, User.password —
# the strictest complexity rule of the four datastore modules):
#   length     >= 12, no documented maximum   -> 32 is inside
#   forbidden  , : =                          -> `-_.~` collides with none
#   complexity "must contain at least 4 unique characters" — a HARD API rule,
#              not a recommendation. The four min_* floors below satisfy it
#              DETERMINISTICALLY: one distinct character from each of the four
#              classes is four unique characters, whatever the draw. This is
#              why the floors are not decorative here.
#
# Unrelated but adjacent, so it does not get rediscovered: the AmazonMQ
# RabbitMQ USERNAME must not contain a tilde. Only the password is generated
# here, so nothing in this module trips that.
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

resource "aws_secretsmanager_secret" "mq_password" {
  count = local.create ? 1 : 0

  name = "${module.naming.name}/password"
  tags = module.naming.tags
}

resource "aws_secretsmanager_secret_version" "mq_password" {
  count = local.create ? 1 : 0

  secret_id     = aws_secretsmanager_secret.mq_password[0].id
  secret_string = random_password.master[0].result
}

################################################################################
# Security group
#
# No egress rule is declared, which matches the pre-v2 stack.
################################################################################

resource "aws_security_group" "mq" {
  count = local.create ? 1 : 0

  name        = "${module.naming.name}-sg"
  description = "Allow traffic to AmazonMQ broker ${local.broker_name}"
  vpc_id      = data.aws_vpc.selected[0].id

  tags = merge(module.naming.tags, { Name = "${module.naming.name}-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "allowed_security_groups" {
  for_each = {
    for pair in setproduct(local.sg_ingress_sgs, local.ingress_ports) :
    "${pair[0]}-${pair[1]}" => { source = pair[0], port = pair[1] }
  }

  security_group_id            = aws_security_group.mq[0].id
  description                  = "AmazonMQ access from ${each.value.source} on port ${each.value.port}"
  referenced_security_group_id = each.value.source
  from_port                    = each.value.port
  to_port                      = each.value.port
  ip_protocol                  = "tcp"

  tags = module.naming.tags
}

resource "aws_vpc_security_group_ingress_rule" "allowed_cidr_blocks" {
  for_each = {
    for pair in setproduct(local.sg_ingress_cidrs, local.ingress_ports) :
    "${pair[0]}-${pair[1]}" => { source = pair[0], port = pair[1] }
  }

  security_group_id = aws_security_group.mq[0].id
  description       = "AmazonMQ access from ${each.value.source} on port ${each.value.port}"
  cidr_ipv4         = each.value.source
  from_port         = each.value.port
  to_port           = each.value.port
  ip_protocol       = "tcp"

  tags = module.naming.tags
}

################################################################################
# Guardrail
#
# A `check` block, not a `precondition`: an unreachable datastore is a
# misconfiguration worth shouting about, but it is not worth making the stack
# un-appliable — an operator may legitimately apply the broker first and wire the
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
      The ${module.naming.name} AmazonMQ broker has NO ingress rule: both
      allowed_cidr_blocks and allowed_security_group_ids are empty and
      allow_vpc_cidr_ingress is false, so the VPC CIDR fallback was skipped.
      Nothing can connect to the broker. Pass allowed_security_group_ids /
      allowed_cidr_blocks, or set allow_vpc_cidr_ingress = true.
    EOT
  }
}

################################################################################
# Broker
################################################################################

resource "aws_mq_broker" "main" {
  count = local.create ? 1 : 0

  broker_name                = local.broker_name
  deployment_mode            = var.broker_deployment_mode
  engine_type                = var.engine_type
  engine_version             = var.engine_version
  host_instance_type         = var.host_instance_type
  publicly_accessible        = var.publicly_accessible
  auto_minor_version_upgrade = var.auto_minor_version_upgrade
  subnet_ids                 = local.subnet_ids
  security_groups            = [aws_security_group.mq[0].id]
  apply_immediately          = var.apply_immediately

  user {
    username = var.mq_admin_user
    password = aws_secretsmanager_secret_version.mq_password[0].secret_string
  }

  logs {
    general = var.enable_general_logs
  }

  tags = merge(module.naming.tags, { Name = local.broker_name })

  # Validation preconditions. These catch AWS-side constraints at plan time
  # instead of ~10 minutes into an apply.
  lifecycle {
    precondition {
      condition     = var.broker_deployment_mode != "ACTIVE_STANDBY_MULTI_AZ"
      error_message = "ACTIVE_STANDBY_MULTI_AZ is only supported for ActiveMQ. This module uses RabbitMQ - use CLUSTER_MULTI_AZ for high availability."
    }

    # AmazonMQ only offers the mq.m5.* and mq.m7g.* families to the RabbitMQ
    # engine. Anything else - mq.t3.micro above all, which the pre-v2 stack used
    # as its dev default - plans cleanly and then fails CreateBroker with
    # "Broker engine type [RabbitMQ] does not support host instance type [...]".
    # This supersedes the old check, which only rejected mq.t3.* under
    # CLUSTER_MULTI_AZ and so let the broken dev shape through.
    precondition {
      condition     = local.host_instance_type_supported
      error_message = "host_instance_type '${var.host_instance_type}' is not offered for the RabbitMQ engine. AmazonMQ accepts only the ${join(" and ", local.supported_instance_families)}* families here: ${join(", ", local.supported_instance_types)}. mq.m7g.medium is the smallest. Note that mq.t2.* / mq.t3.* are ActiveMQ-only and are rejected in EVERY deployment mode, SINGLE_INSTANCE included."
    }

    precondition {
      condition     = !local.is_cluster_deployment || local.distinct_az_count >= 2
      error_message = "CLUSTER_MULTI_AZ deployment mode requires subnets in at least 2 different availability zones. Found ${local.distinct_az_count} distinct AZ(s)."
    }

    precondition {
      condition     = length(data.aws_subnets.selected[0].ids) > 0
      error_message = "No subnets found for tag:Type = ${var.subnet_tag_type}. At least 1 subnet is required for SINGLE_INSTANCE, or subnets in 2-3 different AZs for CLUSTER_MULTI_AZ."
    }
  }
}
