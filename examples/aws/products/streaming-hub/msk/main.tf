################################################################################
# products/streaming-hub/msk — the Kafka the event hub CONSUMES from
#
# streaming-hub is the event delivery edge: it consumes CloudEvents off Kafka and
# fans them out per tenant to webhooks, SQS, RabbitMQ and EventBridge. It is a
# CONSUMER ONLY — it publishes nothing back to Kafka
# (internal/cloudevents/contract.go, and the project snapshot in CLAUDE.md:
# "the hub does not produce lib-streaming events").
#
# THE DEFAULT MODE HERE IS "shared", AND THAT IS THE LOAD-BEARING DECISION.
#
# The hub subscribes by REGEX, not by topic list: ^lerian\.streaming\.<app>$ for
# ingest and ^lerian\.streaming\.<app>\.dlq$ for the DLQ plane
# (internal/ingest/adapters/kafka/client.go:100,107 and
# internal/dlq/adapters/kafka/client.go:77). <app> is the producer's ce-source,
# verbatim. So the hub can only ever see what a PRODUCER wrote to the SAME
# CLUSTER. Give the hub a dedicated broker and it will subscribe successfully,
# report healthy, consume nothing, and no error will be raised anywhere: an
# empty regex match is not a failure condition.
#
# On the consignado wire the producers are br-consignado-gw and lender. Every one
# of them, and this stack, must resolve to shared-{env}-msk — the cluster owned by
# products/shared-resources/msk. mode = "dedicated" here is not a cost tradeoff,
# it is a broken wire.
#
#   mode = "shared"     -> creates NOTHING. Resolves shared-{env}-msk plus the
#                          secret AmazonMSK_shared-{env}-msk. THE DEFAULT.
#   mode = "dedicated"  -> creates streaming-hub-{env}-msk, isolated from every
#                          producer. Only correct if the hub is deployed as an
#                          island for testing.
#
# ONE ROOT STACK PER SERVICE: this directory owns one state file
# (aws/products/streaming-hub/msk/terraform.tfstate). Its sibling, postgres, is an
# independent root with independent state.
#
# TOPICS ARE NOT CREATED HERE, and cannot be. There is no fixed topic list to
# create: the set is whatever ce-source values the producers use, and the hub
# discovers them by regex. auto_create_topics_enable stays false, which means the
# PRODUCERS' topics must exist before the first publish. See README.md — topic
# provisioning is an rpk Job in the helmfile phase, not Terraform.
#
# CONSUMER GROUPS the hub joins, needed for the Kafka ACL grant (which is created
# against the cluster by tenant-manager over the Kafka wire protocol, not by IAM
# and not by Terraform):
#
#   streaming-hub.{STREAMING_HUB_ENV}       ingest plane
#   streaming-hub-dlq.{STREAMING_HUB_ENV}   DLQ plane
#
# and the grant itself is READ-ONLY: PREFIXED READ+DESCRIBE on "lerian.streaming."
# plus LITERAL READ+DESCRIBE on the two groups.
#
# Deploy order: infra-base/vpc -> products/shared-resources/msk -> this stack.
# In shared mode this stack resolves nothing and plans to zero resources, so it is
# cheap to run early; it will simply fail to resolve the cluster until the shared
# tier exists.
#
# This stack does NOT call the naming module. It creates no AWS resource of its
# own, and the two cross-stack names it derives (VPC, EKS cluster) belong to
# infra-base and carry the "lerian" product label.
################################################################################

################################################################################
# Network resolution — _modules/product-network
#
# Pure lookup module, no AWS resource. enabled = (mode == "dedicated") keeps
# shared mode free of lookups: nothing is resolved, nothing is planned, and the
# VPC does not even have to exist.
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
# MSK
#
# In the default shared mode this resolves shared-{env}-msk by name and creates
# nothing. In dedicated mode the secret is AmazonMSK_streaming-hub-{env}-msk —
# AWS mandates the AmazonMSK_ prefix and a customer managed CMK on any secret
# associated with a cluster, which the module handles.
#
# Host handed out: a comma separated bootstrap broker LIST, which is what
# STREAMING_HUB_KAFKA_BROKERS takes.
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
