# All lookups are internal to the module so that a product root stack only has
# to pass product/environment. Nothing is looked up when mode = "shared" except
# the shared cluster and its secret.

# Used by the KMS module to grant key administration to the caller identity.
data "aws_caller_identity" "current" {
  count = local.create ? 1 : 0
}

# VPC by tag:Name, derived from the environment when vpc_name is empty.
data "aws_vpc" "selected" {
  count = local.create ? 1 : 0

  filter {
    name   = "tag:Name"
    values = [local.vpc_name]
  }
}

# Subnets for the DocumentDB subnet group, selected by tag:Type.
data "aws_subnets" "selected" {
  count = local.create ? 1 : 0

  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.selected[0].id]
  }

  tags = {
    Type = var.subnet_tag_type
  }
}

################################################################################
# mode = "shared" — THE ONE PLACE THE SHARED DOCUMENTDB CLUSTER IS RESOLVED
#
# This is deliberately the single point of resolution for the shared cluster.
# If the mechanism below ever has to change, this data source and
# local.shared_identifier in main.tf are the only two things to touch.
#
# WHY aws_rds_cluster AND NOT aws_docdb_cluster
#
# There is no `aws_docdb_cluster` DATA SOURCE in the AWS provider. The docdb
# service ships exactly two data sources — `aws_docdb_engine_version` and
# `aws_docdb_orderable_db_instance` — neither of which resolves an existing
# cluster. DocumentDB clusters are, however, first-class RDS DB clusters in the
# RDS control plane (`aws rds describe-db-clusters` lists them with
# engine = "docdb"), and the provider's aws_rds_cluster data source applies no
# engine filter, so it reads them.
#
# VALIDATED EMPIRICALLY in a real AWS account (us-east-2): a
# DocumentDB cluster created by this module and then read back through
# data "aws_rds_cluster" returned engine = "docdb" plus every attribute shared
# mode needs — endpoint, reader_endpoint (which this module exposes as its own
# reader_endpoint output), port and master_username. This is not an inference
# from the schema; it was measured.
#
# Historical fallbacks, kept only to record what was considered and rejected —
# neither is a pending item: reading the shared-resources/documentdb state with
# terraform_remote_state (couples the product stack to the infra-base state
# file and its backend credentials), or taking the writer endpoint as an
# explicit variable (hardcodes an AWS hostname that changes on cluster
# replacement, which is exactly what resolution by name avoids).
#
# A singular data source fails the plan when nothing matches. That is the wanted
# behaviour: in shared mode there is no fallback, and an unresolvable shared
# cluster must stop the apply rather than emit a null host into Helm values.
################################################################################

data "aws_rds_cluster" "shared" {
  count = local.create ? 0 : 1

  cluster_identifier = local.shared_identifier
}

# mode = "shared": the secret of the cluster owned by shared-resources/documentdb.
data "aws_secretsmanager_secret" "shared" {
  count = local.create ? 0 : 1

  name = local.shared_secret_name
}
