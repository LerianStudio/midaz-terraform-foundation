################################################################################
# products/plugin-fees/valkey
# the OPTIONAL multi-tenant connection-pool registry of plugin-fees
#
# ONE ROOT STACK PER SERVICE. This directory owns exactly one datastore and one
# state file (aws/products/plugin-fees/valkey/terraform.tfstate). Its siblings —
# documentdb and msk — are independent roots with independent state, so a change
# to one can never queue behind an apply of the other and a corrupt state takes
# down one datastore instead of three.
#
#   mode = "dedicated"  -> creates plugin-fees-{env}-valkey, its security group,
#                          its Secrets Manager auth token. This is the default.
#   mode = "shared"     -> creates NOTHING. Resolves the group owned by
#                          products/shared-resources/valkey by name: shared-{env}-valkey
#                          plus the secret shared-{env}-valkey/auth-token.
#
# WHY THIS DIRECTORY EXISTS AT ALL. The discovery YAML
# (infrastructure/IAC/product-infra-dependencies.yaml) recorded plugin-fees as
# `valkey: no`, which is true of the DEFAULT deployment and incomplete as a
# statement about the chart: plugin-fees defines four MULTI_TENANT_REDIS_*
# variables and renders them only when multi-tenancy is on. tracer is the same
# shape and already had a valkey/ root; plugin-fees did not, and the asymmetry
# was an accident of two different batches rather than a decision. This root is
# the tracer one, adapted — see outputs.tf for the two places the charts differ.
#
# Deploy order: infra-base/vpc -> this stack. infra-base/eks can come before or
# after; see check "eks_node_security_group_resolved" in module.network.
#
# This stack does NOT call the naming module. It creates no AWS resource of its
# own, and the two cross-stack names it derives (VPC, EKS cluster) belong to
# infra-base and carry the "lerian" product label — deriving them from a naming
# module seeded with product = "plugin-fees" would produce plugin-fees-{env}-vpc
# and plugin-fees-{env}-eks, which do not exist.
################################################################################

################################################################################
# Network resolution — _modules/product-network
#
# Pure lookup module, no AWS resource. It owns the derived cross-stack names
# (VPC, EKS cluster), the private subnet CIDR lookup, the PLURAL EKS node
# security group lookup and check "eks_node_security_group_resolved". It is
# written once there and consumed identically by every product root.
#
# enabled = (mode == "dedicated") is what keeps shared mode free of lookups: in
# shared mode this stack resolves nothing, plans to zero resources, and does not
# even require the VPC to exist.
#
# subnet_tag_type is deliberately NOT passed. The module's own default is
# "private" — the subnets whose CIDRs become INGRESS. var.subnet_tag_type here
# is "database" and selects the subnets the replication group is PLACED in; it goes to
# the valkey-elasticache module only.
#
# The "nothing can reach this cache at all" case is not asserted anywhere in
# this stack: the valkey-elasticache module already carries check "ingress_is_reachable"
# for it.
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
# Valkey — plugin-fees-{environment}-valkey
# Secret: plugin-fees-{env}-valkey/auth-token   Host: the raw primary endpoint
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
