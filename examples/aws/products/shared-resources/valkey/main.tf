################################################################################
# products/shared-resources/valkey — the SHARED cache/lock tier
#
# ONE ROOT STACK PER SERVICE. This directory owns exactly one datastore and one
# state file (aws/products/shared-resources/valkey/terraform.tfstate). Its
# siblings — postgres, documentdb, rabbitmq, msk — are independent roots with
# independent state.
#
# OPT-IN BY DIRECTORY. There is no valkey_enabled toggle any more. This tier
# used to be a single infra-base/shared-services root with five *_enabled
# booleans in one state file; enabling a datastore is now applying its
# directory, and not applying it is what "disabled" means. See README.md.
#
################################################################################
# READ THIS BEFORE CHANGING mode BELOW.
#
# The module call passes mode = "dedicated". That is correct, and it is the
# single most confusing thing about this model, so it is worth stating plainly:
#
#   var.mode on a datastore module answers "does this module CREATE the
#   resource, or does it merely RESOLVE one that already exists?"
#
#   It does NOT answer "is this resource shared?"
#
# This stack is the real OWNER of the shared Valkey replication group. It
# creates the group, its security group and its Secrets Manager auth token.
# Creating requires mode = "dedicated".
#
# "shared" describes how a PRODUCT CONSUMES what this stack owns. A product root
# stack that sets mode = "shared" creates nothing at all: it resolves the
# endpoint by looking the group up by its derived shared-{env}-valkey name, and
# the token from the secret this stack wrote.
#
#   products/shared-resources/valkey  product = "shared"  mode = "dedicated"  -> creates
#   product root (shared)             product = "midaz"   mode = "shared"     -> resolves
#   product root (dedicated)          product = "midaz"   mode = "dedicated"  -> creates its own
#
# A mode = "shared" here would create nothing and then try to resolve a shared
# group that, by definition, nobody had created. The stack would apply cleanly
# and produce an empty, useless state. That is why mode is NOT a variable in
# this root — it is pinned to the only value that makes sense.
#
# A SHARED CACHE IS ONE KEYSPACE. ElastiCache exposes 16 logical databases per
# node and Terraform creates none of them; two products writing the same key
# name into the same logical database will clobber each other. Coordinating the
# key prefix or the REDIS_DB index across consumers is an application concern
# this stack cannot enforce — it is one of the trade-offs of opting in.
#
################################################################################
# Why product MUST stay "shared"
#
# Shared mode in valkey-elasticache derives the name it looks up from the
# "shared" label: data "aws_elasticache_replication_group" on
# shared-{env}-valkey, and the secret shared-{env}-valkey/auth-token.
# var.product carries a validation pinning it.
#
################################################################################
# TWO PREFIXES, ON PURPOSE
#
#   lerian-{env}-vpc, lerian-{env}-eks   the FOUNDATION (infra-base).
#   shared-{env}-valkey                  the shared DATASTORE tier, created here.
#
# This stack does NOT call the naming module for the two cross-stack names:
# deriving them from a prefix seeded with product = "shared" would look for
# shared-{env}-vpc, which does not exist. _modules/product-network owns that
# derivation and uses the lerian literals.
#
################################################################################
# NO PRIVATE DNS ANYWHERE
#
# This tier used to publish a CNAME AND run transit_encryption_enabled = true
# pointed at it — the exactly-broken combination, since the ElastiCache
# certificate only covers *.{cluster}.{region}.cache.amazonaws.com. The zone is
# gone; endpoint is the raw AWS host.
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
# is "database" and selects the subnets the replication group is PLACED in; it
# goes to the valkey-elasticache module only.
#
# The "nothing can reach this cache at all" case is not asserted here: the
# valkey-elasticache module already carries check "ingress_is_reachable" for it.
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
# Valkey — shared-{environment}-valkey
# Secret: shared-{env}-valkey/auth-token   Host: the raw primary endpoint
################################################################################

module "valkey" {
  source = "../../../_modules/valkey-elasticache"

  product     = var.product
  environment = var.environment
  mode        = "dedicated" # owner of the shared replication group — see the header
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
