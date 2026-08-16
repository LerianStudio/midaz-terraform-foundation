################################################################################
# Cross-stack lookups
#
# The module resolves its own network and shared-cluster references so that a
# product root stack only has to pass product/environment plus sizing.
################################################################################

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

# VPC by tag:Name, derived from the environment when vpc_name is left empty.
data "aws_vpc" "selected" {
  count = local.dedicated ? 1 : 0

  filter {
    name   = "tag:Name"
    values = [local.vpc_name]
  }
}

# Broker subnets, filtered by the Type tag the vpc stack applies.
data "aws_subnets" "selected" {
  count = local.dedicated ? 1 : 0

  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.selected[0].id]
  }

  tags = {
    Type = var.subnet_tag_type
  }
}

################################################################################
# mode = "shared"
#
# Resolution by derived name through a data source — the same shape the other
# four datastore modules now use. MSK was the first module to do it because a
# Kafka cluster has no single host to alias in the first place: it advertises a
# comma separated bootstrap broker list. The rest of the repository converged on
# this pattern when the private-zone CNAMEs were removed, since every AWS
# datastore presents a certificate for its own service domain and an alias in
# front of it breaks TLS hostname verification.
################################################################################

data "aws_msk_cluster" "shared" {
  count = local.shared ? 1 : 0

  cluster_name = "shared-${var.environment}-msk"
}

# SASL/SCRAM credentials of the shared cluster. The AmazonMSK_ prefix is imposed
# by AWS, see credentials.tf. local.shared_secret_name derives
# "AmazonMSK_shared-{environment}-msk" unless var.shared_secret_name overrides it,
# which is the escape hatch for a secret created outside this Terraform.
data "aws_secretsmanager_secret" "shared" {
  count = local.shared && var.enable_sasl_scram ? 1 : 0

  name = local.shared_secret_name
}
