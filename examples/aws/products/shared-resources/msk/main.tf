################################################################################
# products/shared-resources/msk — the SHARED Kafka tier
#
# ONE ROOT STACK PER SERVICE. This directory owns exactly one datastore and one
# state file (aws/products/shared-resources/msk/terraform.tfstate). Its siblings
# — postgres, documentdb, valkey, rabbitmq — are independent roots with
# independent state.
#
# OPT-IN BY DIRECTORY. There is no msk_enabled toggle any more. This tier used
# to be a single infra-base/shared-services root with five *_enabled booleans in
# one state file; enabling a datastore is now applying its directory, and not
# applying it is what "disabled" means. See README.md.
#
# THIS IS THE DIRECTORY MOST CLIENTS SHOULD NOT APPLY. MSK has no cheap corner:
# kafka.t3.small is the smallest broker AWS offers and the broker count must be
# a MULTIPLE of the number of client subnets, so with the three Type=database
# subnets infra-base/vpc creates the floor is THREE brokers, ~USD 105/month. On
# top of that, streaming is off by default in the Lerian charts. There is no
# products/midaz/msk directory for exactly this reason — a product that turns
# streaming on consumes this tier with mode = "shared" rather than paying for
# its own idle cluster.
#
################################################################################
# READ THIS BEFORE CHANGING mode BELOW.
#
# The module call passes mode = "dedicated". That is correct:
#
#   var.mode on a datastore module answers "does this module CREATE the
#   resource, or does it merely RESOLVE one that already exists?"
#
#   It does NOT answer "is this resource shared?"
#
# This stack is the real OWNER of the shared MSK cluster. It creates the
# cluster, its security group, its CMKs and its Secrets Manager entry. Creating
# requires mode = "dedicated".
#
# "shared" describes how a PRODUCT CONSUMES what this stack owns. A product root
# stack that sets mode = "shared" creates nothing at all: it resolves the
# bootstrap brokers by looking the cluster up by its derived shared-{env}-msk
# name, and the SASL/SCRAM credentials from the secret this stack wrote.
#
#   products/shared-resources/msk  product = "shared"  mode = "dedicated"  -> creates
#   product root (shared)          product = "midaz"   mode = "shared"     -> resolves
#
# A mode = "shared" here would create nothing and then try to resolve a shared
# cluster that, by definition, nobody had created. That is why mode is NOT a
# variable in this root — it is pinned to the only value that makes sense.
#
# A SHARED KAFKA CLUSTER IS ONE TOPIC NAMESPACE, one set of ACLs and one
# retention budget. Two products can collide on a topic name; the Lerian charts
# create their topics explicitly from an ArgoCD PreSync rpk job, which is what
# keeps that visible and versioned — and why auto_create_topics_enable stays
# false.
#
################################################################################
# MSK WAS THE TEMPLATE FOR THE WHOLE SHARED MODEL
#
# A Kafka client bootstraps from a comma separated broker list, so there was
# never a single host to alias behind a CNAME. streaming-msk resolved its shared
# cluster with data "aws_msk_cluster" on the derived name from the start; the
# other four datastores converged on the same shape when the private zone was
# removed. "Resolve the shared tier by name" is now the one rule, with no
# exception to remember.
#
# The secret is AmazonMSK_shared-{env}-msk, not the usual {name}/password path:
# the AmazonMSK_ prefix is imposed by AWS on any secret associated with a
# cluster, and it must be encrypted with a customer managed CMK.
#
################################################################################
# Why product MUST stay "shared"
#
# Shared mode in streaming-msk derives what it looks up from the "shared" label:
# data "aws_msk_cluster" on shared-{env}-msk, and the secret
# AmazonMSK_shared-{env}-msk. var.product carries a validation pinning it.
#
################################################################################
# TWO PREFIXES, ON PURPOSE
#
#   lerian-{env}-vpc, lerian-{env}-eks   the FOUNDATION (infra-base).
#   shared-{env}-msk                     the shared DATASTORE tier, created here.
#
# This stack does NOT call the naming module for the two cross-stack names:
# deriving them from a prefix seeded with product = "shared" would look for
# shared-{env}-vpc, which does not exist. _modules/product-network owns that
# derivation and uses the lerian literals.
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
# needs the VPC.
#
# subnet_tag_type is deliberately NOT passed. The module's own default is
# "private" — the subnets whose CIDRs become INGRESS. var.subnet_tag_type here
# is "database" and selects the client subnets the BROKERS are placed in; it
# goes to the streaming-msk module only, alongside var.subnet_ids.
#
# The "nothing can reach this cluster at all" case is not asserted here: the
# streaming-msk module already carries check "ingress_is_reachable" for it. That
# check was added for MSK specifically — the module used to have no VPC-CIDR
# fallback at all, so empty allow lists meant zero ingress and a silently
# unreachable cluster.
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
# MSK — shared-{environment}-msk
# Secret: AmazonMSK_shared-{environment}-msk (the prefix is an AWS requirement)
# Host handed out: a comma separated bootstrap broker list, not a single host
################################################################################

module "msk" {
  source = "../../../_modules/streaming-msk"

  product     = var.product
  environment = var.environment
  mode        = "dedicated" # owner of the shared cluster — see the header
  extra_tags  = var.extra_tags

  vpc_name        = module.network.vpc_name
  subnet_tag_type = var.subnet_tag_type
  subnet_ids      = var.subnet_ids

  allowed_security_group_ids = module.network.ingress_security_group_ids
  allowed_cidr_blocks        = module.network.ingress_cidr_blocks
  allow_vpc_cidr_ingress     = var.allow_vpc_cidr_ingress

  kafka_version                      = var.kafka_version
  number_of_broker_nodes             = var.number_of_broker_nodes
  broker_instance_type               = var.broker_instance_type
  broker_ebs_volume_size             = var.broker_ebs_volume_size
  storage_mode                       = var.storage_mode
  enable_storage_autoscaling         = var.enable_storage_autoscaling
  storage_autoscaling_max_capacity   = var.storage_autoscaling_max_capacity
  storage_autoscaling_target_percent = var.storage_autoscaling_target_percent

  encryption_in_transit_client_broker = var.encryption_in_transit_client_broker

  enable_sasl_scram      = var.enable_sasl_scram
  scram_username         = var.scram_username
  enable_unauthenticated = var.enable_unauthenticated

  auto_create_topics_enable  = var.auto_create_topics_enable
  default_replication_factor = var.default_replication_factor
  extra_server_properties    = var.extra_server_properties

  enhanced_monitoring                    = var.enhanced_monitoring
  cloudwatch_logs_enabled                = var.cloudwatch_logs_enabled
  cloudwatch_log_group_retention_in_days = var.cloudwatch_log_group_retention_in_days
  prometheus_jmx_exporter_enabled        = var.prometheus_jmx_exporter_enabled
  prometheus_node_exporter_enabled       = var.prometheus_node_exporter_enabled
}
