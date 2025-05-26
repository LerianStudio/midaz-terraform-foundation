# Get VPC by filter
data "aws_vpc" "selected" {
  filter {
    name   = "tag:Name"
    values = ["${var.vpc_name}"]
  }
}

# Private Hosted Zone
resource "aws_route53_zone" "private" {
  name = var.private_domain_name

  vpc {
    vpc_id = data.aws_vpc.selected.id
  }

  tags = merge({
    Name        = var.name
    Environment = lower(var.environment)
    ManagedBy   = "Terraform"
  }, var.additional_tags)
}

# VPC Association for Private Zone
resource "aws_route53_vpc_association_authorization" "private" {
  for_each = toset(var.additional_vpcs)

  vpc_id  = each.value
  zone_id = aws_route53_zone.private.id
}
