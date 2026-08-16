################################################################################
# Lookups
#
# The module resolves its own network context so a product root stack needs
# roughly fifteen lines per datastore. Everything is gated on dedicated mode:
# in shared mode this module performs no VPC/subnet lookups at all, only the two
# lookups that describe the instance products/shared-resources/postgres already created.
################################################################################

data "aws_vpc" "selected" {
  count = local.create ? 1 : 0

  filter {
    name   = "tag:Name"
    values = [local.vpc_name]
  }
}

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
# mode = "shared"
#
# The shared instance is resolved BY DERIVED NAME, the same decoupling the rest
# of the repository uses for cross-stack references: no terraform_remote_state,
# no hardcoded endpoint, just "shared-{environment}-postgres" — which is exactly
# what products/shared-resources/postgres creates with product = "shared".
#
# A singular data source fails the plan when nothing matches. That is the wanted
# behaviour here: in shared mode there is no fallback, and an unresolvable shared
# instance must stop the apply rather than emit a null endpoint into Helm values.
################################################################################

data "aws_db_instance" "shared" {
  count = local.create ? 0 : 1

  db_instance_identifier = local.shared_identifier
}

# Shared mode only: the credentials of the instance infra-base already created.
data "aws_secretsmanager_secret" "shared" {
  count = local.create ? 0 : 1

  name = local.shared_secret_name
}
