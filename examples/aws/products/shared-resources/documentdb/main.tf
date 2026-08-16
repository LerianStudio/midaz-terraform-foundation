################################################################################
# products/shared-resources/documentdb — the SHARED MongoDB-compatible tier
#
# ONE ROOT STACK PER SERVICE. This directory owns exactly one datastore and one
# state file (aws/products/shared-resources/documentdb/terraform.tfstate). Its
# siblings — postgres, valkey, rabbitmq, msk — are independent roots with
# independent state.
#
# OPT-IN BY DIRECTORY. There is no documentdb_enabled toggle any more. This tier
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
# This stack is the real OWNER of the shared DocumentDB cluster. It creates the
# cluster, its instances, its security group, its CMK and its Secrets Manager
# entry. Creating requires mode = "dedicated".
#
# "shared" describes how a PRODUCT CONSUMES what this stack owns. A product root
# stack that sets mode = "shared" creates nothing at all: it resolves the
# endpoint by looking the cluster up by its derived shared-{env}-docdb name, and
# the credentials from the secret this stack wrote.
#
#   products/shared-resources/documentdb  product = "shared"  mode = "dedicated"  -> creates
#   product root (shared)                 product = "midaz"   mode = "shared"     -> resolves
#   product root (dedicated)              product = "midaz"   mode = "dedicated"  -> creates its own
#
# A mode = "shared" here would create nothing and then try to resolve a shared
# cluster that, by definition, nobody had created. The stack would apply cleanly
# and produce an empty, useless state. That is why mode is NOT a variable in
# this root — it is pinned to the only value that makes sense.
#
################################################################################
# Why product MUST stay "shared", and why the resource says docdb
#
# Shared mode in mongodb-documentdb derives the name it looks up from the
# "shared" label: data "aws_rds_cluster" on shared-{env}-docdb, and the secret
# shared-{env}-docdb/password. var.product carries a validation pinning it.
#
# The AWS resource suffix is "docdb" (the service); the applications and the
# chart variables say "mongodb". That split is intentional and now lives only in
# the chart variable names — no hostname carries either label any more. Do not
# "align" one of them.
#
# mongodb-documentdb resolves its shared cluster with data "aws_rds_cluster"
# because the provider ships NO data "aws_docdb_cluster" at all — the docdb
# service only exposes aws_docdb_engine_version and
# aws_docdb_orderable_db_instance, neither of which resolves an existing
# cluster. DocumentDB clusters are first-class DB clusters in the RDS control
# plane. Validated in a real AWS account: the data source returns
# engine = "docdb", endpoint, reader_endpoint, port and master_username.
#
################################################################################
# TWO PREFIXES, ON PURPOSE
#
#   lerian-{env}-vpc, lerian-{env}-eks   the FOUNDATION (infra-base).
#   shared-{env}-docdb                   the shared DATASTORE tier, created here.
#
# This stack does NOT call the naming module for the two cross-stack names:
# deriving them from a prefix seeded with product = "shared" would look for
# shared-{env}-vpc, which does not exist. _modules/product-network owns that
# derivation and uses the lerian literals.
#
################################################################################
# NO PRIVATE DNS ANYWHERE
#
# DocumentDB presents a certificate for *.docdb.amazonaws.com, so the private
# CNAME this tier used to publish broke TLS hostname verification — which is why
# documentdb_tls could never be turned on. The zone is gone; endpoint is the raw
# AWS host, the exact name the certificate covers. What still blocks TLS is a
# chart-side gap, not a naming one — see var.documentdb_tls.
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
# is "database" and selects the subnets the cluster is PLACED in; it goes to the
# mongodb-documentdb module only.
#
# The "nothing can reach this cluster at all" case is not asserted here: the
# mongodb-documentdb module already carries check "ingress_is_reachable" for it.
# That check matters more on this tier than on a product root — a product
# consuming with mode = "shared" gets security_group_id = null and cannot
# authorise itself.
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
# DocumentDB — shared-{environment}-docdb
# Secret: shared-{env}-docdb/password   Host: the raw docdb writer endpoint
################################################################################

module "documentdb" {
  source = "../../../_modules/mongodb-documentdb"

  product     = var.product
  environment = var.environment
  mode        = "dedicated" # owner of the shared cluster — see the header
  extra_tags  = var.extra_tags

  vpc_name        = module.network.vpc_name
  subnet_tag_type = var.subnet_tag_type

  allowed_security_group_ids = module.network.ingress_security_group_ids
  allowed_cidr_blocks        = module.network.ingress_cidr_blocks
  allow_vpc_cidr_ingress     = var.allow_vpc_cidr_ingress

  master_username        = var.master_username
  port                   = var.port
  instance_class         = var.instance_class
  instances_count        = var.instances_count
  engine_version         = var.engine_version
  parameter_group_family = var.parameter_group_family
  documentdb_tls         = var.documentdb_tls

  backup_retention_period         = var.backup_retention_period
  preferred_backup_window         = var.preferred_backup_window
  enabled_cloudwatch_logs_exports = var.enabled_cloudwatch_logs_exports
  skip_final_snapshot             = var.skip_final_snapshot
  deletion_protection             = var.deletion_protection
  apply_immediately               = var.apply_immediately
}
