################################################################################
# products/br-sisbajud/msk — the Kafka broker of the br-sisbajud product
#
# ONE ROOT STACK PER SERVICE. This directory owns exactly one datastore and one
# state file (aws/products/br-sisbajud/msk/terraform.tfstate). Its siblings —
# postgres and valkey — are independent roots with independent state. That
# matters most here: an MSK broker replacement is by far the slowest apply of the
# three, and per-service state means it never blocks an RDS parameter change.
#
#   mode = "dedicated"  -> creates br-sisbajud-{env}-msk, its security group, its
#                          two CMKs and its Secrets Manager entry.
#   mode = "shared"     -> creates NOTHING. Resolves the cluster owned by
#                          products/shared-resources/msk by name: shared-{env}-msk
#                          plus the secret AmazonMSK_shared-{env}-msk.
#
# READ THIS BEFORE PICKING dedicated.
#
# MSK HAS NO CHEAP CORNER. kafka.t3.small is the smallest broker AWS offers, the
# minimum is two brokers, AND the broker count must be a MULTIPLE of the number
# of client subnets. infra-base/vpc tags THREE subnets Type=database, so the
# valid values are 3, 6, 9 — the real floor is THREE brokers, roughly
# USD 105/month, per product, before a single message is published.
#
# mode = "shared" against products/shared-resources/msk is therefore the NORMAL
# choice and mode = "dedicated" is the justified exception. What justifies it
# here, if anything, is regulatory isolation rather than cost or throughput:
# br-sisbajud carries judicial asset blocking and unblocking ordered through
# BACEN SISBAJUD, and a SHARED Kafka cluster is one topic namespace, one set of
# ACLs and one retention budget for every product pointed at it. If the
# deployment has to be able to state that no other workload can read or replay
# those events, that is an isolation argument, and it is the one this directory
# exists to serve. Absent that argument, set mode = "shared".
#
# NOTE that the chart does NOT force the choice: br-sisbajud requires streaming
# (STREAMING_ENABLED defaults to "true" and STREAMING_BROKERS is marked REQUIRED
# in values-template.yaml:23-24), but "a broker" is not "its own broker". Nothing
# in the chart or its docs asks for a dedicated cluster.
#
# TOPICS ARE NOT CREATED HERE, and that is not an omission — see README.md. The
# chart ships an ArgoCD PreSync Job that runs `rpk topic create` for its six
# topics; Terraform provisions the cluster and stops there.
#
# Deploy order: infra-base/vpc -> this stack. infra-base/eks can come before or
# after; see check "eks_node_security_group_resolved" in the network module.
#
# This stack does NOT call the naming module. It creates no AWS resource of its
# own, and the two cross-stack names it derives (VPC, EKS cluster) belong to
# infra-base and carry the "lerian" product label — deriving them from a naming
# module seeded with product = "br-sisbajud" would produce br-sisbajud-{env}-vpc
# and br-sisbajud-{env}-eks, which do not exist.
################################################################################

################################################################################
# Network resolution — _modules/product-network
#
# Pure lookup module, no AWS resource. It owns the derived cross-stack names
# (VPC, EKS cluster), the private subnet CIDR lookup, the PLURAL EKS node
# security group lookup and check "eks_node_security_group_resolved".
#
# enabled = (mode == "dedicated") is what keeps shared mode free of lookups: in
# shared mode this stack resolves nothing, plans to zero resources, and does not
# even require the VPC to exist.
#
# subnet_tag_type is deliberately NOT passed. The module's own default is
# "private" — the subnets whose CIDRs become INGRESS. var.subnet_tag_type here
# is "database" and selects the CLIENT SUBNETS the brokers are PLACED in; it
# goes to the streaming-msk module only, alongside var.subnet_ids.
#
# The "nothing can reach this cluster at all" case is not asserted here: the
# streaming-msk module already carries check "ingress_is_reachable" for it. That
# check was added for MSK specifically — the module used to have no VPC-CIDR
# fallback at all, so empty allow lists meant zero ingress and a cluster that
# looked healthy and accepted no connections.
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
# MSK — br-sisbajud-{environment}-msk
#
# Secret: AmazonMSK_br-sisbajud-{env}-msk. THE PREFIX IS NOT THE USUAL SHAPE.
# Every other Lerian datastore writes {name}/password or {name}/auth-token; AWS
# REQUIRES the literal AmazonMSK_ prefix on any secret associated with an MSK
# cluster through aws_msk_scram_secret_association, and requires it to be
# encrypted with a customer managed CMK. The module handles both.
#
# Host handed out: a comma separated bootstrap broker LIST, not a single host.
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

  # auto.create.topics.enable stays false. The chart creates its six topics
  # explicitly from an ArgoCD PreSync rpk Job, which keeps the topic set
  # versioned with the service that owns it — see README.md.
  auto_create_topics_enable  = var.auto_create_topics_enable
  default_replication_factor = var.default_replication_factor
  extra_server_properties    = var.extra_server_properties

  enhanced_monitoring                    = var.enhanced_monitoring
  cloudwatch_logs_enabled                = var.cloudwatch_logs_enabled
  cloudwatch_log_group_retention_in_days = var.cloudwatch_log_group_retention_in_days
  prometheus_jmx_exporter_enabled        = var.prometheus_jmx_exporter_enabled
  prometheus_node_exporter_enabled       = var.prometheus_node_exporter_enabled
}
