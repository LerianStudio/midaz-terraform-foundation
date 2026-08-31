# All lookups are internal to the module so that a product root stack only has
# to pass product/environment. Nothing is looked up when mode = "shared" except
# the shared broker and its secret.

# VPC by tag:Name, derived from the environment when vpc_name is empty.
data "aws_vpc" "selected" {
  count = local.create ? 1 : 0

  filter {
    name   = "tag:Name"
    values = [local.vpc_name]
  }
}

# Candidate subnets for broker placement, selected by tag:Type.
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

# Detailed information for each candidate subnet, needed for the availability
# zone of each one so CLUSTER_MULTI_AZ can be spread one subnet per AZ.
data "aws_subnet" "selected" {
  for_each = local.create ? toset(data.aws_subnets.selected[0].ids) : toset([])

  id = each.value
}

################################################################################
# mode = "shared"
#
# The shared broker is resolved BY NAME, like every other cross-stack reference
# in this repository — no terraform_remote_state, no hardcoded endpoint.
#
# THE TOPOLOGY SUFFIX. Unlike the other datastores, the AmazonMQ broker name is
# not simply "shared-{environment}-rabbitmq": append_deployment_suffix (default
# true, on both sides) appends -single or -cluster so a SINGLE_INSTANCE ->
# CLUSTER_MULTI_AZ migration can run the two brokers side by side
# (docs/UPGRADE-GUIDE.md). The secret and the security group never carry the
# suffix; the broker does.
#
# data "aws_mq_broker" accepts broker_id or broker_name and matches EXACTLY —
# the AWS provider ships no list/filter data source for MQ, so the suffix cannot
# be discovered, it has to be declared. var.shared_broker_name carries it, and
# defaults to the -single shape because that is what the shared-resources/rabbitmq dev and
# module defaults produce. A wrong suffix does not fail silently: the singular
# data source fails the plan naming the broker it looked for.
################################################################################

data "aws_mq_broker" "shared" {
  count = local.create ? 0 : 1

  broker_name = local.shared_broker_name
}

# mode = "shared": the secret of the broker owned by shared-resources/rabbitmq. It carries
# no topology suffix, which is why it resolves regardless of the broker's shape.
data "aws_secretsmanager_secret" "shared" {
  count = local.create ? 0 : 1

  name = local.shared_secret_name
}
