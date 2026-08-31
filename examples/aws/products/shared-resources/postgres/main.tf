################################################################################
# products/shared-resources/postgres — the SHARED PostgreSQL tier
#
# ONE ROOT STACK PER SERVICE. This directory owns exactly one datastore and one
# state file (aws/products/shared-resources/postgres/terraform.tfstate). Its
# siblings — documentdb, valkey, rabbitmq, msk — are independent roots with
# independent state, so a broker replacement can never queue behind an RDS apply
# and a corrupt state takes down one datastore instead of five.
#
# OPT-IN BY DIRECTORY. There is no postgres_enabled toggle any more. This tier
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
# This stack is the real OWNER of the shared PostgreSQL instance. It creates the
# RDS instance, its security group and its Secrets Manager entry. Creating
# requires mode = "dedicated". There is no other value that creates anything.
#
# "shared" describes how a PRODUCT CONSUMES what this stack owns. A product root
# stack that sets mode = "shared" creates nothing at all: it resolves the
# endpoint by looking the instance up by its derived shared-{env}-postgres name,
# and the credentials from the secret this stack wrote.
#
#   products/shared-resources/postgres  product = "shared"  mode = "dedicated"  -> creates
#   product root (shared)               product = "midaz"   mode = "shared"     -> resolves
#   product root (dedicated)            product = "midaz"   mode = "dedicated"  -> creates its own
#
# A mode = "shared" here would create nothing and then try to resolve a shared
# instance that, by definition, nobody had created. The stack would apply
# cleanly and produce an empty, useless state. That is why mode is NOT a
# variable in this root — it is pinned to the only value that makes sense.
#
################################################################################
# Why product MUST stay "shared"
#
# Shared mode in postgres-rds does not take the shared product as an input — it
# derives the name it looks up from the "shared" label: data "aws_db_instance"
# on shared-{env}-postgres, and the secret shared-{env}-postgres/password. With
# product = "shared" this stack produces exactly those strings, which is why
# var.product carries a validation pinning it.
#
################################################################################
# TWO PREFIXES, ON PURPOSE
#
#   lerian-{env}-vpc, lerian-{env}-eks   the FOUNDATION (infra-base). Unconditionally
#                                        shared, no dedicated counterpart exists, so a
#                                        "shared" label would carry no information.
#   shared-{env}-postgres                the shared DATASTORE tier, created here.
#                                        Here the dedicated/shared choice does exist,
#                                        and the label is exactly what separates
#                                        shared-dev-postgres from midaz-dev-postgres
#                                        at a glance.
#
# Do not "fix" this into a single prefix. This stack does NOT call the naming
# module for the two cross-stack names: deriving them from a prefix seeded with
# product = "shared" would look for shared-{env}-vpc, which does not exist.
# _modules/product-network owns that derivation and uses the lerian literals.
#
################################################################################
# NO PRIVATE DNS ANYWHERE
#
# This tier used to publish a {component}.lerian.{zone} CNAME and shared
# consumers resolved it through DNS. That is gone: RDS presents a certificate
# for *.{region}.rds.amazonaws.com, so a private CNAME in front of it breaks TLS
# hostname verification. Consumers now resolve the tier by NAME through a data
# source, and endpoint is the raw AWS host.
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
# is "database" and selects the subnets the instance is PLACED in; it goes to
# the postgres-rds module only.
#
# The "nothing can reach this instance at all" case is not asserted here: the
# postgres-rds module already carries check "ingress_is_reachable" for it. That
# check matters more on this tier than on a product root — a product consuming
# with mode = "shared" gets security_group_id = null and cannot authorise
# itself, so an unreachable shared instance is unreachable for everyone.
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
# PostgreSQL — shared-{environment}-postgres
# Secret: shared-{env}-postgres/password   Host: the raw RDS endpoint
################################################################################

module "postgres" {
  source = "../../../_modules/postgres-rds"

  product     = var.product
  environment = var.environment
  mode        = "dedicated" # owner of the shared instance — see the header
  extra_tags  = var.extra_tags

  vpc_name        = module.network.vpc_name
  subnet_tag_type = var.subnet_tag_type

  allowed_security_group_ids = module.network.ingress_security_group_ids
  allowed_cidr_blocks        = module.network.ingress_cidr_blocks
  allow_vpc_cidr_ingress     = var.allow_vpc_cidr_ingress

  engine_version       = var.engine_version
  family               = var.family
  major_engine_version = var.major_engine_version
  database_name        = var.database_name
  username             = var.username

  instance_class        = var.instance_class
  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  multi_az              = var.multi_az

  create_read_replica         = var.create_read_replica
  read_replica_instance_class = var.read_replica_instance_class
  read_replica_multi_az       = var.read_replica_multi_az

  backup_retention_period = var.backup_retention_period
  skip_final_snapshot     = var.skip_final_snapshot
  deletion_protection     = var.deletion_protection

  monitoring_interval                   = var.monitoring_interval
  create_monitoring_role                = var.create_monitoring_role
  performance_insights_enabled          = var.performance_insights_enabled
  performance_insights_retention_period = var.performance_insights_retention_period

  enabled_cloudwatch_logs_exports = var.enabled_cloudwatch_logs_exports
  create_cloudwatch_log_group     = length(var.enabled_cloudwatch_logs_exports) > 0
}
