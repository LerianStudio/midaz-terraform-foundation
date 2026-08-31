################################################################################
# products/br-consignado-gw/msk — the Kafka the gateway PUBLISHES the consignado
# fact stream to
#
# br-consignado-gw is the Dataprev gateway: the money path at the border. It
# produces every consignado fact — all 21 definitions ride one route — and it
# consumes the lender command plane.
#
# THE DEFAULT MODE HERE IS "shared", AND THAT IS THE LOAD-BEARING DECISION.
#
# streaming-hub consumes what this gateway produces, and it subscribes BY REGEX:
# ^lerian\.streaming\.<app>$, where <app> is the producer's ce-source verbatim. A
# regex can only match a topic on the SAME CLUSTER. Give the gateway a dedicated
# broker and it publishes happily into a broker nobody reads — a Kafka producer is
# never told whether anyone is listening, and an empty regex match on the consumer
# side is not a failure condition either. Both ends report healthy and no fact is
# ever delivered.
#
#   mode = "shared"     -> creates NOTHING. Resolves the cluster owned by
#                          products/shared-resources/msk by name: shared-{env}-msk
#                          plus the secret AmazonMSK_shared-{env}-msk. THE DEFAULT.
#   mode = "dedicated"  -> creates br-consignado-gw-{env}-msk, isolated from the
#                          hub. Only correct to run the gateway as an island for
#                          testing.
#
# Cost reinforces the same answer. MSK has no cheap corner: kafka.t3.small is the
# smallest broker AWS offers, and the broker count must be a MULTIPLE of the number
# of client subnets — infra-base/vpc tags THREE as Type=database, so the real floor
# is three brokers, roughly USD 105/month, per product, before a single message.
#
# ONE ROOT STACK PER SERVICE. This directory owns one state file
# (aws/products/br-consignado-gw/msk/terraform.tfstate); postgres, valkey, s3 and
# secrets are independent roots with independent state.
#
# TOPICS ARE NOT CREATED HERE, by anything. auto.create.topics.enable is false so a
# typo fails loudly instead of producing a live topic with broker defaults that
# nobody consumes. Provisioning is an rpk Job in the helmfile phase; the list this
# estate needs is in ../../lerian-platform/README.md and in the `topics` output.
#
# THE SASL CREDENTIALS ARE FILE PATHS, NOT VALUES. See README.md — this is the one
# service on the estate that reads them from disk, so the projected secret has to
# be a mounted volume rather than environment variables.
#
# Deploy order: infra-base/vpc -> products/shared-resources/msk -> this stack. In
# shared mode it resolves nothing and plans to zero resources.
#
# This stack does NOT call the naming module. It creates no AWS resource of its
# own, and the two cross-stack names it derives (VPC, EKS cluster) belong to
# infra-base and carry the "lerian" product label — deriving them from a naming
# module seeded with product = "br-consignado-gw" would produce
# br-consignado-gw-{env}-vpc and -eks, which do not exist.
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
# MSK — shared-{environment}-msk in the default shared mode
#
# Secret: AmazonMSK_shared-{env}-msk. THE PREFIX IS NOT THE USUAL SHAPE.
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

  # Kept FALSE. Nothing on this estate creates topics implicitly, so a typo in a
  # producer topic name fails loudly instead of silently creating a live topic
  # with broker defaults that the hub's regex never matches. The rpk Job in the
  # helmfile phase owns creation; see README.md before flipping it.
  auto_create_topics_enable  = var.auto_create_topics_enable
  default_replication_factor = var.default_replication_factor
  extra_server_properties    = var.extra_server_properties

  enhanced_monitoring                    = var.enhanced_monitoring
  cloudwatch_logs_enabled                = var.cloudwatch_logs_enabled
  cloudwatch_log_group_retention_in_days = var.cloudwatch_log_group_retention_in_days
  prometheus_jmx_exporter_enabled        = var.prometheus_jmx_exporter_enabled
  prometheus_node_exporter_enabled       = var.prometheus_node_exporter_enabled
}
