# Get VPC by name tag
data "aws_vpc" "selected" {
  filter {
    name   = "tag:Name"
    values = [var.vpc_name]
  }
}

# Find all database subnets within the VPC
data "aws_subnets" "cache" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.selected.id]
  }

  tags = {
    Type = "database"
  }
}
