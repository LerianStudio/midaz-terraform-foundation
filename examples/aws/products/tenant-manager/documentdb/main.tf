################################################################################
# products/tenant-manager/documentdb — the MongoDB-compatible datastore of tenant-manager
#
################################################################################
# THE COMPOSITION OF THIS PRODUCT IS INFERRED, NOT READ. READ ../README.md.
#
# tenant-manager has NO readable Helm chart in this monorepo. The directory
# infrastructure/K8S/helm/charts/tenant-manager/ contains exactly two files:
#
#   charts/mongodb-16.4.0.tgz    Bitnami, byte-identical to plugin-fees' copy
#   charts/valkey-0.7.4.tgz      valkey-io/valkey-helm, upstream
#
# There is no Chart.yaml, no values.yaml, no templates/. `helm template` on that
# directory fails. What is left behind is the output of a `helm dependency
# build` whose parent chart was never committed.
#
# So the INFRASTRUCTURE is well founded — two vendored datastore subcharts is
# unambiguous evidence that tenant-manager runs on MongoDB and Valkey, which is also
# what product-infra-dependencies.yaml records — while the CHART CONTRACT is
# not. Not one tenant-manager-side environment variable name appears in any readable
# file. outputs.tf therefore publishes the endpoints and emits an EMPTY
# helm_values rather than a plausible-looking guess. See the header there.
#
################################################################################
#
# ONE ROOT STACK PER SERVICE. This directory owns exactly one datastore and one
# state file (aws/products/tenant-manager/documentdb/terraform.tfstate). Its sibling
# valkey/ is an independent root with independent state.
#
#   mode = "dedicated"  -> creates tenant-manager-{env}-docdb, its security group, its
#                          CMK and its Secrets Manager entry.
#   mode = "shared"     -> creates NOTHING. Resolves the cluster owned by
#                          products/shared-resources/documentdb by name:
#                          shared-{env}-docdb plus the secret
#                          shared-{env}-docdb/password.
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
# is "database" and selects the subnets the cluster is PLACED in.
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
# DocumentDB — tenant-manager-{environment}-docdb
# Secret: tenant-manager-{env}-docdb/password   Host: the raw docdb writer endpoint
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
