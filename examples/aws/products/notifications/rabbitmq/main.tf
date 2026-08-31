################################################################################
# products/notifications/rabbitmq — the message broker of the notifications product
#
# The broker carries the outbox dispatch and the three delivery queues (email,
# sms, webhook). Every component reads the same RABBITMQ_* block from the shared
# ConfigMap and Secret.
#
# ONE ROOT STACK PER SERVICE. This directory owns exactly one datastore and one
# state file (aws/products/notifications/rabbitmq/terraform.tfstate). Its siblings —
# postgres, valkey — are independent roots with independent state.
# An AmazonMQ broker replacement is the slowest apply of the three, and
# per-service state means it never blocks an RDS parameter change.
#
#   mode = "dedicated"  -> creates notifications-{env}-rabbitmq[-single|-cluster],
#                          its security group and its Secrets Manager entry.
#   mode = "shared"     -> creates NOTHING. Resolves the broker owned by
#                          products/shared-resources/rabbitmq by name (see
#                          var.shared_broker_name for the topology suffix), plus
#                          the secret shared-{env}-rabbitmq/password.
#
# TWO DIFFERENT "MODE" AXES live in this stack and they are unrelated:
#   var.mode                    dedicated | shared                 Lerian sharing
#   var.broker_deployment_mode  SINGLE_INSTANCE | CLUSTER_MULTI_AZ AWS topology
# The broker NAME carries the topology suffix; the secret and the security group
# never do. A shared consumer therefore resolves the SECRET without knowing the
# topology, but has to declare it for the BROKER lookup — var.shared_broker_name.
#
# Deploy order: infra-base/vpc -> this stack. infra-base/eks can come before or
# after; see check "eks_node_security_group_resolved" in module.network.
#
# This stack does NOT call the naming module. It creates no AWS resource of its
# own, and the two cross-stack names it derives (VPC, EKS cluster) belong to
# infra-base and carry the "lerian" product label.
################################################################################

################################################################################
# Network resolution — _modules/product-network
#
# Pure lookup module, no AWS resource. It owns the derived cross-stack names
# (VPC, EKS cluster), the private subnet CIDR lookup, the PLURAL EKS
# node security group lookup and check "eks_node_security_group_resolved". It is
# written once there and consumed identically by every product root, including
# the postgres, valkey siblings of this one.
#
# enabled = (mode == "dedicated") is what keeps shared mode free of lookups: in
# shared mode this stack resolves nothing, plans to zero resources, and does not
# even require the VPC to exist.
#
# subnet_tag_type is deliberately NOT passed. The module's own default is
# "private" — the subnets whose CIDRs become INGRESS. var.subnet_tag_type here
# is "database" and selects the subnets the broker is PLACED in; it goes to
# the rabbitmq-amazonmq module only.
#
# The "nothing can reach this broker at all" case is not asserted anywhere in
# this stack: the rabbitmq-amazonmq module already carries check
# "ingress_is_reachable" for it.
################################################################################

module "network" {
  source = "../../../_modules/product-network"

  enabled     = var.mode == "dedicated"
  environment = var.environment

  vpc_name         = var.vpc_name
  eks_cluster_name = var.eks_cluster_name

  allow_private_subnet_cidr_ingress      = var.allow_private_subnet_cidr_ingress
  eks_node_security_group_lookup_enabled = var.eks_node_security_group_lookup_enabled

  allowed_security_group_ids = var.allowed_security_group_ids
  allowed_cidr_blocks        = var.allowed_cidr_blocks
}

################################################################################
# RabbitMQ — notifications-{environment}-rabbitmq[-single|-cluster]
# Secret: notifications-{env}-rabbitmq/password   Host: the raw AmazonMQ broker host
################################################################################

module "rabbitmq" {
  source = "../../../_modules/rabbitmq-amazonmq"

  product     = var.product
  environment = var.environment
  mode        = var.mode
  extra_tags  = var.extra_tags

  # Only read when mode = "shared". It carries the -single / -cluster suffix of
  # the shared broker, which the lookup cannot discover — see the variable.
  shared_broker_name = var.shared_broker_name

  vpc_name        = module.network.vpc_name
  subnet_tag_type = var.subnet_tag_type

  allowed_security_group_ids = module.network.ingress_security_group_ids
  allowed_cidr_blocks        = module.network.ingress_cidr_blocks
  allow_vpc_cidr_ingress     = var.allow_vpc_cidr_ingress

  # Ingress is scoped to AMQPS (5671) plus the management console (443). The
  # console stays open because the chart's RABBITMQ_HEALTH_CHECK_URL targets the
  # management HTTP API on that port.
  port                   = var.port
  console_port           = var.console_port
  enable_console_ingress = var.enable_console_ingress

  broker_deployment_mode   = var.broker_deployment_mode
  append_deployment_suffix = var.append_deployment_suffix
  engine_version           = var.engine_version
  host_instance_type       = var.host_instance_type
  mq_admin_user            = var.mq_admin_user

  auto_minor_version_upgrade = var.auto_minor_version_upgrade
  apply_immediately          = var.apply_immediately
  enable_general_logs        = var.enable_general_logs
}
