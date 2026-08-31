################################################################################
# products/flowker/valkey — the cache/lock datastore of flowker
#
################################################################################
# THE COMPOSITION OF THIS PRODUCT IS INFERRED, NOT READ. READ ../README.md.
#
# flowker has NO readable Helm chart in this monorepo. The evidence for this
# directory existing at all is a vendored valkey-0.7.4.tgz sitting next to
# mongodb-16.4.0.tgz in infrastructure/K8S/helm/charts/flowker/charts/, with no
# Chart.yaml, no values.yaml and no templates/ anywhere above them.
#
# That is good evidence that flowker RUNS ON a Valkey, and no evidence at all
# about which environment variable carries the host. outputs.tf therefore
# publishes the endpoint and emits an EMPTY helm_values. See the header there.
#
################################################################################
#
# ONE ROOT STACK PER SERVICE. This directory owns exactly one datastore and one
# state file (aws/products/flowker/valkey/terraform.tfstate). Its sibling
# documentdb/ is an independent root with independent state.
#
#   mode = "dedicated"  -> creates flowker-{env}-valkey, its security group, its
#                          Secrets Manager auth token. This is the default.
#   mode = "shared"     -> creates NOTHING. Resolves the group owned by
#                          products/shared-resources/valkey by name:
#                          shared-{env}-valkey plus the secret
#                          shared-{env}-valkey/auth-token.
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
# (VPC, EKS cluster), the private subnet CIDR lookup, the PLURAL EKS node
# security group lookup and check "eks_node_security_group_resolved".
#
# enabled = (mode == "dedicated") is what keeps shared mode free of lookups.
#
# subnet_tag_type is deliberately NOT passed. The module's own default is
# "private" — the subnets whose CIDRs become INGRESS. var.subnet_tag_type here
# is "database" and selects the subnets the replication group is PLACED in.
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
# Valkey — flowker-{environment}-valkey
# Secret: flowker-{env}-valkey/auth-token   Host: the raw primary endpoint
################################################################################

module "valkey" {
  source = "../../../_modules/valkey-elasticache"

  product     = var.product
  environment = var.environment
  mode        = var.mode
  extra_tags  = var.extra_tags

  vpc_name        = module.network.vpc_name
  subnet_tag_type = var.subnet_tag_type

  allowed_security_group_ids = module.network.ingress_security_group_ids
  allowed_cidr_blocks        = module.network.ingress_cidr_blocks
  allow_vpc_cidr_ingress     = var.allow_vpc_cidr_ingress

  engine_version         = var.engine_version
  parameter_group_family = var.parameter_group_family
  port                   = var.port

  node_type                  = var.node_type
  num_cache_clusters         = var.num_cache_clusters
  automatic_failover_enabled = var.automatic_failover_enabled
  multi_az_enabled           = var.multi_az_enabled
  snapshot_retention_limit   = var.snapshot_retention_limit

  transit_encryption_enabled = var.transit_encryption_enabled
  transit_encryption_mode    = var.transit_encryption_mode
  auth_token_enabled         = var.auth_token_enabled

  maintenance_window = var.maintenance_window
  apply_immediately  = var.apply_immediately
}
