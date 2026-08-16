################################################################################
# products/plugin-br-bank-transfer/documentdb — the MongoDB-compatible datastore of plugin-br-bank-transfer
#
# Audit and event persistence for the TED lifecycle. The chart calls this
# datastore MANDATORY (values.yaml: "MongoDB configuration (mandatory for
# audit/event persistence)") and bundles a Bitnami mongodb subchart enabled by
# default.
#
# ONE ROOT STACK PER SERVICE. This directory owns exactly one datastore and one
# state file (aws/products/plugin-br-bank-transfer/documentdb/terraform.tfstate). Its siblings —
# postgres, valkey, rabbitmq — are independent roots with independent state,
# so a broker change can never queue behind an RDS apply and a corrupt state
# takes down one datastore instead of four.
#
#   mode = "dedicated"  -> creates plugin-br-bank-transfer-{env}-docdb, its security group,
#                          its CMK and its Secrets Manager entry.
#   mode = "shared"     -> creates NOTHING. Resolves the cluster owned by
#                          products/shared-resources/documentdb by name:
#                          shared-{env}-docdb plus the secret
#                          shared-{env}-docdb/password.
#
# The AWS resource suffix is "docdb" and the chart variables say "mongo". That is
# intentional (docdb is the service, mongodb is what the applications speak). The
# split lives only in those variable NAMES — the host they carry is the raw
# *.docdb.amazonaws.com endpoint in both modes.
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
# (VPC, EKS cluster), the private subnet CIDR lookup, the PLURAL EKS
# node security group lookup and check "eks_node_security_group_resolved". It is
# written once there and consumed identically by every product root, including
# the postgres, valkey, rabbitmq siblings of this one.
#
# enabled = (mode == "dedicated") is what keeps shared mode free of lookups: in
# shared mode this stack resolves nothing, plans to zero resources, and does not
# even require the VPC to exist.
#
# subnet_tag_type is deliberately NOT passed. The module's own default is
# "private" — the subnets whose CIDRs become INGRESS. var.subnet_tag_type here
# is "database" and selects the subnets the cluster is PLACED in; it goes to
# the mongodb-documentdb module only.
#
# The "nothing can reach this cluster at all" case is not asserted anywhere in
# this stack: the mongodb-documentdb module already carries check
# "ingress_is_reachable" for it.
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
# DocumentDB — plugin-br-bank-transfer-{environment}-docdb
# Secret: plugin-br-bank-transfer-{env}-docdb/password   Host: the raw docdb writer endpoint
################################################################################

module "documentdb" {
  source = "../../../_modules/mongodb-documentdb"

  product     = var.product
  environment = var.environment
  mode        = var.mode
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
