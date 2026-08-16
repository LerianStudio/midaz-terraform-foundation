################################################################################
# products/plugin-br-pix-switch/rabbitmq — the broker of the Pix switch DICT
# verification sync worker
#
# ONE COMPONENT USES IT. Of the chart's ten components only dict/hub/vsync reads
# RABBITMQ_URI, a full amqps:// connection URL with the password inside it
# (values-template.yaml:104). The chart already decided AmazonMQ is the target:
# "For external RabbitMQ / AmazonMQ set enabled: false and configure
#  dictHubVsync.secrets.RABBITMQ_URI" (values.yaml:1493-1494), and the embedded
# subchart is disabled because it "would present a self-signed cert that
# lib-commons rejects" (values.yaml:1465-1468).#
# THE CHART CONSUMES CONNECTION URLS, NOT host/port PAIRS. This is the single
# structural difference from every other product in this repository, and it
# changes what helm_values can carry — read the header of outputs.tf before
# wiring anything.

#
# ONE ROOT STACK PER SERVICE. This directory owns exactly one datastore and one
# state file (aws/products/plugin-br-pix-switch/rabbitmq/terraform.tfstate). Its
# siblings — postgres, documentdb and valkey — are independent roots with
# independent state. That matters most here: an AmazonMQ broker replacement is
# the slowest apply of the four, and per-service state means it never blocks an
# RDS parameter change.
#
#   mode = "dedicated"  -> creates plugin-br-pix-switch-{env}-rabbitmq[-single|-cluster], its
#                          security group and its Secrets Manager entry. This is
#                          the default.
#   mode = "shared"     -> creates NOTHING. Resolves the broker owned by
#                          products/shared-resources/rabbitmq by name (see
#                          var.shared_broker_name for the topology suffix), plus
#                          the secret shared-{env}-rabbitmq/password.
#
# TWO DIFFERENT "MODE" AXES live in this stack and they are unrelated:
#   var.mode                    dedicated | shared         Lerian sharing contract
#   var.broker_deployment_mode  SINGLE_INSTANCE | CLUSTER_MULTI_AZ   AWS topology
# The broker NAME carries the topology suffix; the secret and the security group
# never do. A shared consumer therefore resolves the SECRET without knowing the
# topology, but has to declare it for the BROKER lookup — var.shared_broker_name.
#
# Deploy order: infra-base/vpc -> this stack. infra-base/eks
# can come before or after; see check "eks_node_security_group_resolved" below.
#
# This stack does NOT call the naming module. It creates no AWS resource of its
# own, and the two cross-stack names it derives (VPC, EKS cluster)
# belong to infra-base and carry the "lerian" product label.
################################################################################

################################################################################
# Network resolution — _modules/product-network
#
# Pure lookup module, no AWS resource. It owns the derived cross-stack names
# (VPC, EKS cluster), the private subnet CIDR lookup, the PLURAL EKS
# node security group lookup and check "eks_node_security_group_resolved". All
# of that used to be ~90 lines duplicated verbatim in this stack and in its
# three siblings; it is written once there and consumed here.
#
# enabled = (mode == "dedicated") is what keeps shared mode free of lookups: in
# shared mode this stack resolves nothing, plans to zero resources, and does not
# even require the VPC to exist. Note that `enabled` tracks var.mode, the Lerian
# sharing axis — NOT var.broker_deployment_mode, the AWS topology axis.
#
# subnet_tag_type is deliberately NOT passed. The module's own default is
# "private" — the subnets whose CIDRs become INGRESS. var.subnet_tag_type here
# is "database" and selects the subnets the broker is PLACED in; it goes to the
# rabbitmq-amazonmq module only.
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
# RabbitMQ — plugin-br-pix-switch-{environment}-rabbitmq[-single|-cluster]
# Secret: plugin-br-pix-switch-{env}-rabbitmq/password   Host: the raw AmazonMQ broker host
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
  # console is opened by default for operator access only: unlike midaz,
  # no plugin-br-pix-switch component calls the management HTTP API — this chart
  # names no health-check URL variable — so turning it off is a defensible
  # tightening rather than a broken health check.
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
