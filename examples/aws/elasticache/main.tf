locals {
  environment = lower(var.environment)
  name        = var.name
  tags = merge({
    Name        = "elasticache-${local.name}-${local.environment}"
    Environment = local.environment
    ManagedBy   = "Terraform"
  }, var.additional_tags)
}

data "aws_vpc" "selected" {
  id = var.vpc_id
}

data "aws_subnets" "cache" {
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }

  tags = {
    Type = "private"
  }
}

resource "aws_security_group" "redis" {
  name_prefix = "${local.name}-${local.environment}-redis-"
  description = "Security group for Redis cluster"
  vpc_id      = var.vpc_id

  ingress {
    description = "Allow Redis port access"
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.selected.cidr_block]
  }

  tags = local.tags
}

resource "aws_elasticache_subnet_group" "this" {
  name       = "${local.name}-${local.environment}-redis-subnet"
  subnet_ids = data.aws_subnets.cache.ids
  tags       = local.tags
}

resource "aws_elasticache_parameter_group" "this" {
  family      = var.family
  name        = "${local.name}-${local.environment}-redis-params"
  description = "Redis parameter group for ${local.name}-${local.environment}"

  dynamic "parameter" {
    for_each = var.parameters
    content {
      name  = parameter.value.name
      value = parameter.value.value
    }
  }

  tags = local.tags
}

resource "aws_elasticache_replication_group" "this" {
  replication_group_id = "${local.name}-${local.environment}"
  description          = "Redis cluster for ${local.name}-${local.environment}"

  node_type            = var.node_type
  port                 = 6379
  parameter_group_name = aws_elasticache_parameter_group.this.name
  subnet_group_name    = aws_elasticache_subnet_group.this.name

  engine             = "redis"
  engine_version     = var.engine_version
  num_cache_clusters = var.environment == "prod" ? 2 : 1

  automatic_failover_enabled = var.environment == "prod"
  multi_az_enabled           = var.environment == "prod"

  maintenance_window       = "sun:05:00-sun:09:00"
  snapshot_window          = "00:00-04:00"
  snapshot_retention_limit = var.environment == "prod" ? 7 : 1

  security_group_ids = [aws_security_group.redis.id]

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true

  tags = local.tags
}

# DNS Record
resource "aws_route53_record" "redis" {
  count   = var.create_dns_record ? 1 : 0
  zone_id = var.route53_zone_id
  name    = "${var.dns_name}.${var.dns_zone_name}"
  type    = "CNAME"
  ttl     = 300
  records = [aws_elasticache_replication_group.this.primary_endpoint_address]
}
