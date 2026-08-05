# Get VPC by name tag
data "aws_vpc" "selected" {
  filter {
    name   = "tag:Name"
    values = [var.vpc_name]
  }
}

# Get all private subnet IDs from the selected VPC for AmazonMQ broker placement
data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.selected.id]
  }

  tags = {
    Type = "private"
  }
}

# Get detailed information for each private subnet (including availability zone)
data "aws_subnet" "private" {
  for_each = toset(data.aws_subnets.private.ids)
  id       = each.value
}