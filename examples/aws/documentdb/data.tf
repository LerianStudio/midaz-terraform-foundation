# Get AWS caller identity
data "aws_caller_identity" "current" {}

# Get VPC by name tag
data "aws_vpc" "selected" {
  filter {
    name   = "tag:Name"
    values = [var.vpc_name]
  }
}

# Get all private subnet IDs from the selected VPC for DocumentDB cluster placement
data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.selected.id]
  }

  tags = {
    Type = "private"
  }
}
