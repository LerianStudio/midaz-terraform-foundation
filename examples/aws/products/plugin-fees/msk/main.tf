################################################################################
# products/plugin-fees/msk — the OPTIONAL Kafka datastore of plugin-fees
#
# ONE ROOT STACK PER SERVICE. This directory owns exactly one datastore and one
# state file (aws/products/plugin-fees/msk/terraform.tfstate). Its sibling
# documentdb/ is an independent root with independent state.
#
################################################################################
# READ THIS BEFORE APPLYING THIS DIRECTORY AT ALL.
#
# STREAMING IS OFF BY DEFAULT IN THE CHART. plugin-fees-helm 7.3.0 renders
# STREAMING_ENABLED = "false" (templates/fees/configmap.yaml:120; the key is not
# even present in values.yaml). Applying this directory with mode = "dedicated"
# for a feature nobody turned on buys idle brokers.
#
# AND MSK HAS NO CHEAP CORNER. kafka.t3.small is the smallest broker AWS offers,
# the minimum is two brokers, and number_of_broker_nodes must be a MULTIPLE of
# the number of client subnets. infra-base/vpc tags THREE subnets Type=database,
# so the valid values are 3, 6, 9 — three brokers is the real floor, roughly
# USD 105/month. A 2-broker cluster requires subnet_ids narrowed to exactly two
# subnet ids, which cannot be written into a tfvars-example because the ids are
# generated.
#
# THE NORMAL ANSWER IS mode = "shared".
#
#   mode = "shared" (the recommended value for this product, and what every
#                    tfvars-example in envs/ ships)
#       Creates NOTHING. Resolves the cluster owned by
#       products/shared-resources/msk by name — shared-{env}-msk — plus the
#       SASL/SCRAM secret AmazonMSK_shared-{env}-msk. A fee engine emitting
#       CloudEvents is a low-volume publisher; a dedicated three-broker cluster
#       for it is hard to justify against a shared tier that already exists.
#
#   mode = "dedicated" (the default of var.mode, kept for uniformity with every
#                       other product root — NOT a recommendation here)
#       Creates plugin-fees-{env}-msk, its security group, its CMKs and its
#       Secrets Manager entry. Choose it when fee events must not share a topic
#       namespace, an ACL set or a retention budget with any other product.
#
# Deploy order: infra-base/vpc -> infra-base/eks -> [products/shared-resources/msk
# if mode = "shared"] -> this stack. In shared mode the shared cluster MUST
# already exist: data "aws_msk_cluster" is singular and fails the plan when it
# does not match, which is the desired behaviour — a shared cluster that cannot
# be resolved has to stop the apply rather than emit a null broker list into the
# Helm values.
#
# This stack does NOT call the naming module. It creates no AWS resource of its
# own, and the two cross-stack names it derives (VPC, EKS cluster) belong to
# infra-base and carry the "lerian" product label.
################################################################################

################################################################################
# Network resolution — _modules/product-network
#
# Pure lookup module, no AWS resource. It owns the derived cross-stack names
# (VPC, EKS cluster), the private subnet CIDR lookup, the PLURAL EKS node
# security group lookup and check "eks_node_security_group_resolved".
#
# enabled = (mode == "dedicated") is what keeps shared mode free of lookups.
#
# subnet_tag_type is deliberately NOT passed. The module's own default is
# "private" — the subnets whose CIDRs become INGRESS. var.subnet_tag_type here
# is "database" and selects the CLIENT SUBNETS the brokers are placed in; it
# goes to the streaming-msk module only, alongside var.subnet_ids.
#
# The "nothing can reach this cluster at all" case is not asserted here: the
# streaming-msk module already carries check "ingress_is_reachable". That check
# was added for MSK specifically — the module used to have no VPC-CIDR fallback
# at all, so empty allow lists meant zero ingress and a silently unreachable
# cluster.
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
# MSK — plugin-fees-{environment}-msk in dedicated mode
#
# Secret: AmazonMSK_plugin-fees-{env}-msk (the AmazonMSK_ prefix and the customer
# managed CMK are both AWS requirements on any secret associated with a cluster),
# or AmazonMSK_shared-{env}-msk when resolving the shared tier.
#
# Host handed out: a comma separated bootstrap broker list, not a single host —
# which is why MSK never needed a CNAME and why it was the template the other
# four datastores converged on when the private zone was removed.
#
# In mode = "shared" a product creates no security group, so it cannot authorise
# itself on the shared cluster: opening it is products/shared-resources/msk's job.
################################################################################

module "msk" {
  source = "../../../_modules/streaming-msk"

  product     = var.product
  environment = var.environment
  mode        = var.mode
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
