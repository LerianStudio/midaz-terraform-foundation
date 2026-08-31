################################################################################
# Amazon MSK — the AWS implementation of the Lerian STREAMING_* contract
#
# The Lerian Helm charts talk to a Kafka API through lib-streaming (CloudEvents)
# and are configured with STREAMING_* values. RedPanda is never a subchart, the
# broker is always external, and on AWS that broker is MSK.
#
# Required by: br-sisbajud, br-sfn.
# Optional for: midaz, plugin-fees.
#
# TOPICS ARE NOT MANAGED HERE. Each chart creates its own topics from an
# ArgoCD PreSync job running `rpk`, so the topic set stays versioned with the
# service that owns it. See README.md.
################################################################################

module "naming" {
  source = "../naming"

  product     = var.product
  environment = var.environment
  component   = "msk"
  extra_tags  = var.extra_tags
}

locals {
  dedicated = var.mode == "dedicated"
  shared    = var.mode == "shared"

  vpc_name = var.vpc_name != "" ? var.vpc_name : "lerian-${var.environment}-vpc"

  broker_subnet_ids = local.dedicated ? (
    length(var.subnet_ids) > 0 ? var.subnet_ids : data.aws_subnets.selected[0].ids
  ) : []

  # Which wire protocols the cluster will actually answer on.
  plaintext_in_transit = contains(["PLAINTEXT", "TLS_PLAINTEXT"], var.encryption_in_transit_client_broker)
  tls_in_transit       = contains(["TLS", "TLS_PLAINTEXT"], var.encryption_in_transit_client_broker)

  # MSK listener ports, opened only for the authentication modes in use:
  #   9092 plaintext / unauthenticated
  #   9094 TLS (mutual TLS client auth, or unauthenticated over TLS)
  #   9096 SASL/SCRAM
  broker_ports = distinct(concat(
    local.plaintext_in_transit && var.enable_unauthenticated ? [9092] : [],
    local.tls_in_transit && (var.enable_tls_client_auth || var.enable_unauthenticated) ? [9094] : [],
    local.tls_in_transit && var.enable_sasl_scram ? [9096] : [],
  ))

  # Port a client should use with the strongest mode enabled, exported as `port`.
  client_port = var.enable_sasl_scram ? 9096 : (local.tls_in_transit ? 9094 : 9092)

  ################################################################################
  # Ingress — THE single rule, identical in all five datastore modules
  #
  #   any entry in allowed_cidr_blocks or allowed_security_group_ids
  #     -> exactly those sources are allowed, and NOTHING else. The VPC CIDR is
  #        never added on top. A caller who restricts, restricts.
  #
  #   both lists empty
  #     -> fall back to the VPC CIDR when allow_vpc_cidr_ingress is true, or to no
  #        ingress rule at all when it is false.
  #
  # The fallback is NEW here. This module previously had none, so two empty lists
  # produced zero ingress rules and a cluster no client could reach, with nothing
  # in the plan output saying so. Either half of that is now fixed: the fallback
  # keeps the cluster reachable, and check "ingress_is_reachable" warns whenever
  # the resolved set still comes out empty.
  #
  # Every rule is scoped to the listener ports the enabled authentication modes
  # actually use (local.broker_ports), never to a whole protocol.
  ################################################################################
  vpc_cidr = try(data.aws_vpc.selected[0].cidr_block, "")

  has_explicit_allow_list = length(var.allowed_cidr_blocks) > 0 || length(var.allowed_security_group_ids) > 0

  ingress_cidr_blocks = (
    local.has_explicit_allow_list
    ? var.allowed_cidr_blocks
    : (var.allow_vpc_cidr_ingress ? compact([local.vpc_cidr]) : [])
  )

  sg_ingress_cidrs = local.dedicated ? local.ingress_cidr_blocks : []
  sg_ingress_sgs   = local.dedicated ? var.allowed_security_group_ids : []

  # Shared mode: the SASL/SCRAM secret of the cluster infra-base already created.
  # AWS forces the AmazonMSK_ prefix on any secret associated with an MSK cluster,
  # so the override is validated against it in variables.tf.
  shared_secret_name = (
    var.shared_secret_name != ""
    ? var.shared_secret_name
    : "AmazonMSK_shared-${var.environment}-msk"
  )

  # Never let the replication factor exceed the broker count, which is what
  # breaks a single-AZ dev cluster.
  default_replication_factor = coalesce(var.default_replication_factor, min(var.number_of_broker_nodes, 3))

  server_properties = merge(
    {
      "auto.create.topics.enable"  = tostring(var.auto_create_topics_enable)
      "default.replication.factor" = tostring(local.default_replication_factor)
    },
    var.extra_server_properties,
  )

  encryption_at_rest_kms_key_arn = var.encryption_at_rest_kms_key_arn != "" ? var.encryption_at_rest_kms_key_arn : one(module.msk_kms_key[*].key_arn)

  # Endpoint resolution. Dedicated reads the module, shared reads the data source.
  bootstrap_brokers            = local.dedicated ? one(module.msk[*].bootstrap_brokers) : one(data.aws_msk_cluster.shared[*].bootstrap_brokers)
  bootstrap_brokers_tls        = local.dedicated ? one(module.msk[*].bootstrap_brokers_tls) : one(data.aws_msk_cluster.shared[*].bootstrap_brokers_tls)
  bootstrap_brokers_sasl_scram = local.dedicated ? one(module.msk[*].bootstrap_brokers_sasl_scram) : one(data.aws_msk_cluster.shared[*].bootstrap_brokers_sasl_scram)
  zookeeper_connect_string     = local.dedicated ? one(module.msk[*].zookeeper_connect_string) : one(data.aws_msk_cluster.shared[*].zookeeper_connect_string)

  # `endpoint` carries the bootstrap list matching the strongest enabled auth
  # mode. This is the STREAMING_BROKERS value for the Helm values.
  brokers_for_clients = var.enable_sasl_scram ? local.bootstrap_brokers_sasl_scram : (
    local.tls_in_transit ? local.bootstrap_brokers_tls : local.bootstrap_brokers
  )
}

################################################################################
# Security group
################################################################################

resource "aws_security_group" "msk" {
  count = local.dedicated ? 1 : 0

  name        = "${module.naming.name}-sg"
  description = "Kafka client access to the ${module.naming.name} MSK cluster"
  vpc_id      = data.aws_vpc.selected[0].id

  tags = merge(module.naming.tags, { Name = "${module.naming.name}-sg" })

  lifecycle {
    precondition {
      condition     = var.enable_sasl_scram || var.enable_tls_client_auth || var.enable_unauthenticated
      error_message = "At least one client authentication mode must be enabled: enable_sasl_scram, enable_tls_client_auth or enable_unauthenticated."
    }

    precondition {
      condition     = !var.enable_sasl_scram || local.tls_in_transit
      error_message = "SASL/SCRAM requires encryption in transit. Set encryption_in_transit_client_broker to TLS or TLS_PLAINTEXT, or disable enable_sasl_scram."
    }

    precondition {
      condition     = !var.enable_tls_client_auth || (local.tls_in_transit && length(var.tls_certificate_authority_arns) > 0)
      error_message = "Mutual TLS client authentication requires encryption_in_transit_client_broker set to TLS or TLS_PLAINTEXT and at least one entry in tls_certificate_authority_arns."
    }

    precondition {
      condition     = contains([2, 3], length(local.broker_subnet_ids))
      error_message = "MSK accepts exactly 2 or 3 client subnets. The lookup for tag:Type=${var.subnet_tag_type} in VPC ${local.vpc_name} did not return 2 or 3 subnets — narrow subnet_tag_type or pass subnet_ids explicitly."
    }

    precondition {
      condition     = var.number_of_broker_nodes % length(local.broker_subnet_ids) == 0
      error_message = "The number_of_broker_nodes must be a multiple of the number of client subnets, which AWS enforces on the cluster."
    }
  }
}

# Ingress from peer security groups, per enabled listener port.
resource "aws_vpc_security_group_ingress_rule" "from_security_groups" {
  for_each = {
    for pair in setproduct(local.sg_ingress_sgs, local.broker_ports) :
    "${pair[0]}-${pair[1]}" => { source = pair[0], port = pair[1] }
  }

  security_group_id            = aws_security_group.msk[0].id
  referenced_security_group_id = each.value.source
  from_port                    = each.value.port
  to_port                      = each.value.port
  ip_protocol                  = "tcp"
  description                  = "Kafka clients from ${each.value.source} on port ${each.value.port}"

  tags = merge(module.naming.tags, { Name = "${module.naming.name}-in-sg-${each.value.port}" })
}

# Ingress from CIDR blocks, per enabled listener port.
resource "aws_vpc_security_group_ingress_rule" "from_cidr_blocks" {
  for_each = {
    for pair in setproduct(local.sg_ingress_cidrs, local.broker_ports) :
    "${pair[0]}-${pair[1]}" => { source = pair[0], port = pair[1] }
  }

  security_group_id = aws_security_group.msk[0].id
  cidr_ipv4         = each.value.source
  from_port         = each.value.port
  to_port           = each.value.port
  ip_protocol       = "tcp"
  description       = "Kafka clients from ${each.value.source} on port ${each.value.port}"

  tags = merge(module.naming.tags, { Name = "${module.naming.name}-in-cidr-${each.value.port}" })
}

# Brokers talk to each other and to AWS endpoints.
#
# The default is 0.0.0.0/0, which matches the effective posture of every other
# datastore in this repository: a security group created by Terraform keeps the
# allow-all egress rule that AWS attaches on creation, so the legacy stacks are
# equally open, they just never wrote it down. Declaring it makes the posture
# reviewable and, more importantly, tunable via egress_cidr_blocks.
#
# trivy/tfsec flag this as AWS-0104 / aws-ec2-no-public-egress-sgr, which
# scripts/run-tfsec.sh already excludes repository-wide. Narrow it to the VPC CIDR
# by setting egress_cidr_blocks if the environment does not need broker egress to
# AWS public endpoints.
# trivy:ignore:AWS-0104
resource "aws_vpc_security_group_egress_rule" "all" {
  for_each = local.dedicated ? toset(var.egress_cidr_blocks) : toset([])

  security_group_id = aws_security_group.msk[0].id
  cidr_ipv4         = each.value
  ip_protocol       = "-1"
  description       = "Allow outbound traffic to ${each.value}"

  tags = merge(module.naming.tags, { Name = "${module.naming.name}-egress" })
}

################################################################################
# Guardrail
#
# A `check` block, not a `precondition`: an unreachable cluster is a
# misconfiguration worth shouting about, but it is not worth making the stack
# un-appliable — an operator may legitimately apply the cluster first and wire the
# allow list in a second pass.
################################################################################

check "ingress_is_reachable" {
  assert {
    condition = (
      !local.dedicated
      || (
        length(local.broker_ports) > 0
        && (length(local.sg_ingress_cidrs) > 0 || length(local.sg_ingress_sgs) > 0)
      )
    )
    error_message = <<-EOT
      The ${module.naming.name} MSK cluster has NO ingress rule. Either both
      allowed_cidr_blocks and allowed_security_group_ids are empty while
      allow_vpc_cidr_ingress is false (so the VPC CIDR fallback was skipped), or the
      enabled authentication modes resolved to no listener port at all. No Kafka
      client can reach the brokers. Pass allowed_security_group_ids /
      allowed_cidr_blocks, or set allow_vpc_cidr_ingress = true.
      Resolved listener ports: [${join(", ", [for p in local.broker_ports : tostring(p)])}].
    EOT
  }
}

################################################################################
# Cluster
################################################################################

module "msk" {
  source  = "terraform-aws-modules/msk-kafka-cluster/aws"
  version = "~> 3.3.0"

  count = local.dedicated ? 1 : 0

  name          = module.naming.name
  kafka_version = var.kafka_version

  # Broker nodes
  number_of_broker_nodes      = var.number_of_broker_nodes
  broker_node_instance_type   = var.broker_instance_type
  broker_node_client_subnets  = local.broker_subnet_ids
  broker_node_security_groups = [aws_security_group.msk[0].id]

  broker_node_storage_info = {
    ebs_storage_info = {
      volume_size = var.broker_ebs_volume_size
    }
  }

  storage_mode               = var.storage_mode != "" ? var.storage_mode : null
  enable_storage_autoscaling = var.enable_storage_autoscaling
  scaling_max_capacity       = var.storage_autoscaling_max_capacity
  scaling_target_value       = var.storage_autoscaling_target_percent

  # Encryption: CMK at rest, TLS in transit, always encrypted between brokers.
  encryption_at_rest_kms_key_arn      = local.encryption_at_rest_kms_key_arn
  encryption_in_transit_client_broker = var.encryption_in_transit_client_broker
  encryption_in_transit_in_cluster    = true

  # Client authentication
  client_authentication = {
    sasl = {
      scram = var.enable_sasl_scram
    }
    tls = var.enable_tls_client_auth ? {
      certificate_authority_arns = var.tls_certificate_authority_arns
    } : null
    unauthenticated = var.enable_unauthenticated
  }

  # The association is ordered after the credentials are written by the
  # depends_on at the bottom of this block, since MSK validates the secret
  # contents at association time.
  create_scram_secret_association          = var.enable_sasl_scram
  scram_secret_association_secret_arn_list = var.enable_sasl_scram ? [aws_secretsmanager_secret.scram[0].arn] : []

  # server.properties
  create_configuration            = var.create_configuration
  configuration_name              = "${module.naming.name}-config"
  configuration_description       = "Kafka configuration for ${module.naming.name}"
  configuration_server_properties = local.server_properties

  # Logging. create_cloudwatch_log_group is gated here because the upstream
  # module would otherwise create the group even with streaming disabled.
  cloudwatch_logs_enabled                = var.cloudwatch_logs_enabled
  create_cloudwatch_log_group            = var.cloudwatch_logs_enabled
  cloudwatch_log_group_name              = "/aws/msk/${module.naming.name}"
  cloudwatch_log_group_retention_in_days = var.cloudwatch_log_group_retention_in_days
  cloudwatch_log_group_kms_key_id        = var.cloudwatch_log_group_kms_key_arn != "" ? var.cloudwatch_log_group_kms_key_arn : null

  # Monitoring
  enhanced_monitoring   = var.enhanced_monitoring
  jmx_exporter_enabled  = var.prometheus_jmx_exporter_enabled
  node_exporter_enabled = var.prometheus_node_exporter_enabled

  # Schemas live with the services, not in Glue.
  create_schema_registry = false

  tags = module.naming.tags

  depends_on = [
    aws_secretsmanager_secret_version.scram,
    aws_secretsmanager_secret_policy.scram,
  ]
}
