# Current AWS identity, used as KMS key administrator/user.
data "aws_caller_identity" "current" {}

# VPC created by the infra-base/vpc stack, resolved by tag:Name.
data "aws_vpc" "selected" {
  filter {
    name   = "tag:Name"
    values = [local.vpc_name]
  }
}

# Subnets tagged Type=<subnet_tag_type> (private by default) inside that VPC.
# Nodes and the control plane ENIs are placed here.
data "aws_subnets" "selected" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.selected.id]
  }

  tags = {
    Type = var.subnet_tag_type
  }
}
