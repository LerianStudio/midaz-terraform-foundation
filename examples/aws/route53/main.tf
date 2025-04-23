locals {
  environment = lower(var.environment)
  name        = var.name
  tags = merge({
    Name        = "route53-${local.name}-${local.environment}"
    Environment = local.environment
    ManagedBy   = "Terraform"
  }, var.additional_tags)
}

# Private Hosted Zone
resource "aws_route53_zone" "private" {
  name = var.private_domain_name

  vpc {
    vpc_id = var.vpc_id
  }

  tags = local.tags
}

# VPC Association for Private Zone
resource "aws_route53_vpc_association_authorization" "private" {
  for_each = toset(var.additional_vpcs)

  vpc_id  = each.value
  zone_id = aws_route53_zone.private.id
}
