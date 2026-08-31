################################################################################
# products/shared-resources/rabbitmq — the SHARED message broker tier
#
# ONE ROOT STACK PER SERVICE. This directory owns exactly one datastore and one
# state file (aws/products/shared-resources/rabbitmq/terraform.tfstate). Its
# siblings — postgres, documentdb, valkey, msk — are independent roots with
# independent state. That matters most here: an AmazonMQ broker replacement is
# the slowest apply of the five, and per-service state means it never blocks an
# RDS parameter change.
#
# OPT-IN BY DIRECTORY. There is no rabbitmq_enabled toggle any more. This tier
# used to be a single infra-base/shared-services root with five *_enabled
# booleans in one state file; enabling a datastore is now applying its
# directory, and not applying it is what "disabled" means. See README.md.
#
################################################################################
# READ THIS BEFORE CHANGING mode BELOW.
#
# TWO DIFFERENT "MODE" AXES live in this stack and they are unrelated:
#
#   the module's `mode`      dedicated | shared                Lerian sharing contract
#   var.broker_deployment_mode  SINGLE_INSTANCE | CLUSTER_MULTI_AZ   AWS topology
#
# The module call passes mode = "dedicated". That is correct:
#
#   var.mode on a datastore module answers "does this module CREATE the
#   resource, or does it merely RESOLVE one that already exists?"
#
#   It does NOT answer "is this resource shared?"
#
# This stack is the real OWNER of the shared broker. It creates the broker, its
# security group and its Secrets Manager entry. Creating requires
# mode = "dedicated".
#
# "shared" describes how a PRODUCT CONSUMES what this stack owns. A product root
# stack that sets mode = "shared" creates nothing at all: it resolves the broker
# by name and the credentials from the secret this stack wrote.
#
#   products/shared-resources/rabbitmq  product = "shared"  mode = "dedicated"  -> creates
#   product root (shared)               product = "midaz"   mode = "shared"     -> resolves
#   product root (dedicated)            product = "midaz"   mode = "dedicated"  -> creates its own
#
# A mode = "shared" here would create nothing and then try to resolve a shared
# broker that, by definition, nobody had created. That is why mode is NOT a
# variable in this root — it is pinned to the only value that makes sense.
#
################################################################################
# THIS STACK DECIDES THE TOPOLOGY SUFFIX A SHARED CONSUMER MUST DECLARE
#
# append_deployment_suffix (default true) makes the broker name carry the
# topology: shared-{env}-rabbitmq-single or shared-{env}-rabbitmq-cluster. The
# SECRET and the SECURITY GROUP never carry it — only the broker.
#
# data "aws_mq_broker" matches broker_name EXACTLY and the AWS provider ships no
# list/filter data source for MQ, so a shared consumer cannot DISCOVER the
# suffix: it has to DECLARE it, through shared_broker_name on its own root.
#
#   this stack                       consumer must set
#   broker_deployment_mode           shared_broker_name
#   ------------------------------   -------------------------------------
#   SINGLE_INSTANCE   (dev default)  "" — the derived default already matches
#                                    shared-{env}-rabbitmq-single
#   CLUSTER_MULTI_AZ  (stg, prd)     "shared-{env}-rabbitmq-cluster"
#
# CHANGING broker_deployment_mode HERE IS A BREAKING CHANGE FOR EVERY SHARED
# CONSUMER. Their plans fail — loudly, naming the broker they searched for — not
# silently. The suffix is also what makes the migration side by side: the two
# brokers coexist while consumers are moved one at a time. See
# _modules/rabbitmq-amazonmq/docs/UPGRADE-GUIDE.md.
#
################################################################################
# Why product MUST stay "shared"
#
# Shared mode in rabbitmq-amazonmq derives what it looks up from the "shared"
# label: shared-{env}-rabbitmq-{single|cluster} for the broker, and the secret
# shared-{env}-rabbitmq/password. var.product carries a validation pinning it.
#
################################################################################
# TWO PREFIXES, ON PURPOSE
#
#   lerian-{env}-vpc, lerian-{env}-eks   the FOUNDATION (infra-base).
#   shared-{env}-rabbitmq[-suffix]       the shared DATASTORE tier, created here.
#
# This stack does NOT call the naming module for the two cross-stack names:
# deriving them from a prefix seeded with product = "shared" would look for
# shared-{env}-vpc, which does not exist. _modules/product-network owns that
# derivation and uses the lerian literals.
#
################################################################################
# NO PRIVATE DNS ANYWHERE
#
# AmazonMQ presents a certificate for *.mq.{region}.on.aws and exposes no
# plaintext AMQP listener, so every client speaks AMQPS and a private CNAME in
# front of the broker breaks hostname verification. endpoint is the raw AWS host.
#
# Deploy order: infra-base/vpc -> infra-base/eks -> this stack -> products.
################################################################################

################################################################################
# Network resolution — _modules/product-network
#
# Pure lookup module, no AWS resource. It owns the derived cross-stack names
# (VPC, EKS cluster), the private subnet CIDR lookup, the PLURAL EKS node
# security group lookup and check "eks_node_security_group_resolved".
#
# enabled = true, unconditionally: unlike a product root, this stack has no
# shared mode to switch the lookups off for. It always creates, so it always
# needs the VPC. Note this tracks the sharing axis, NOT
# var.broker_deployment_mode.
#
# subnet_tag_type is deliberately NOT passed. The module's own default is
# "private" — the subnets whose CIDRs become INGRESS. var.subnet_tag_type here
# is "database" and selects the subnets the broker is PLACED in; it goes to the
# rabbitmq-amazonmq module only.
#
# The "nothing can reach this broker at all" case is not asserted here: the
# rabbitmq-amazonmq module already carries check "ingress_is_reachable" for it.
################################################################################

module "network" {
  source = "../../../_modules/product-network"

  enabled     = true
  environment = var.environment

  vpc_name         = var.vpc_name
  eks_cluster_name = var.eks_cluster_name

  allow_private_subnet_cidr_ingress      = var.allow_private_subnet_cidr_ingress
  eks_node_security_group_lookup_enabled = var.eks_node_security_group_lookup_enabled

  allowed_security_group_ids = var.allowed_security_group_ids
  allowed_cidr_blocks        = var.allowed_cidr_blocks
}

################################################################################
# RabbitMQ — shared-{environment}-rabbitmq[-single|-cluster]
# Secret: shared-{env}-rabbitmq/password   Host: the raw AmazonMQ broker host
################################################################################

module "rabbitmq" {
  source = "../../../_modules/rabbitmq-amazonmq"

  product     = var.product
  environment = var.environment
  mode        = "dedicated" # owner of the shared broker — see the header
  extra_tags  = var.extra_tags

  # shared_broker_name is NOT passed: it is only read in shared mode, and this
  # stack is the one that CREATES the broker whose name a shared consumer has to
  # declare on its own side.

  vpc_name        = module.network.vpc_name
  subnet_tag_type = var.subnet_tag_type

  allowed_security_group_ids = module.network.ingress_security_group_ids
  allowed_cidr_blocks        = module.network.ingress_cidr_blocks
  allow_vpc_cidr_ingress     = var.allow_vpc_cidr_ingress

  # Ingress is scoped to AMQPS (5671) plus the management console (443). The
  # console is opened by default: the midaz ledger's RABBITMQ_HEALTH_CHECK_URL
  # targets the management HTTP API on that port.
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
