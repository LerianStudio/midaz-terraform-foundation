################################################################################
# products/midaz/postgres — the PostgreSQL datastore of the midaz product
#
# ONE ROOT STACK PER SERVICE. This directory owns exactly one datastore and one
# state file (aws/products/midaz/postgres/terraform.tfstate). Its siblings —
# documentdb, valkey, rabbitmq — are independent roots with independent state,
# so a RabbitMQ change can never queue behind an RDS apply and a corrupt state
# takes down one datastore instead of four.
#
#   mode = "dedicated"  -> creates midaz-{env}-postgres, its security group, its
#                          Secrets Manager entry. This is the default.
#   mode = "shared"     -> creates NOTHING. Resolves the instance owned by
#                          products/shared-resources/postgres by name: shared-{env}-postgres
#                          plus the secret shared-{env}-postgres/password.
#
# Deploy order: infra-base/vpc -> this stack. infra-base/eks
# can come before or after; see check "eks_node_security_group_resolved" below.
#
# This stack does NOT call the naming module. It creates no AWS resource of its
# own, and the two cross-stack names it derives (VPC, EKS cluster)
# belong to infra-base and carry the "lerian" product label — deriving them from
# a naming module seeded with product = "midaz" would produce midaz-{env}-vpc and
# midaz-{env}-eks, which do not exist.
################################################################################

################################################################################
# Network resolution — _modules/product-network
#
# Pure lookup module, no AWS resource. It owns the derived cross-stack names
# (VPC, EKS cluster), the private subnet CIDR lookup, the PLURAL EKS
# node security group lookup and check "eks_node_security_group_resolved". All
# of that used to be ~90 lines duplicated verbatim in this stack and in its
# three siblings; it is written once there and consumed here.
#
# enabled = (mode == "dedicated") is what keeps shared mode free of lookups: in
# shared mode this stack resolves nothing, plans to zero resources, and does not
# even require the VPC to exist.
#
# subnet_tag_type is deliberately NOT passed. The module's own default is
# "private" — the subnets whose CIDRs become INGRESS. var.subnet_tag_type here
# is "database" and selects the subnets the instance is PLACED in; it goes to
# the postgres-rds module only.
#
# The "nothing can reach this instance at all" case is not asserted anywhere in
# this stack: the postgres-rds module already carries check
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
# PostgreSQL — midaz-{environment}-postgres
# Secret: midaz-{env}-postgres/password   Host: the raw RDS endpoint
################################################################################

module "postgres" {
  source = "../../../_modules/postgres-rds"

  product     = var.product
  environment = var.environment
  mode        = var.mode
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
