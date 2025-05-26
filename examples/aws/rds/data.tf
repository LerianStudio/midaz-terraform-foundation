# Get VPC by name tag
data "aws_vpc" "selected" {
  filter {
    name   = "tag:Name"
    values = ["${var.vpc_name}"]
  }
}

# Get database subnets
data "aws_subnets" "database" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.selected.id]
  }

  tags = {
    Type = "database"
  }
}

# Get Route53 zone
data "aws_route53_zone" "selected" {
  name         = var.dns_zone_name
  private_zone = true
  vpc_id       = data.aws_vpc.selected.id
}
