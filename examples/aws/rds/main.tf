locals {
  environment = lower(var.environment)
  name        = var.name
  tags = merge({
    Name        = "rds-${local.name}-${local.environment}"
    Environment = local.environment
    ManagedBy   = "Terraform"
  }, var.additional_tags)
}

data "aws_subnets" "database" {
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }

  tags = {
    Type = "database"
  }
}

resource "aws_security_group" "rds" {
  name_prefix = "${local.name}-${local.environment}-rds-"
  description = "Security group for RDS instance"
  vpc_id      = var.vpc_id

  ingress {
    description = "Allow database port access"
    from_port   = var.port
    to_port     = var.port
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.selected.cidr_block]
  }

  tags = local.tags
}

module "db" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 5.0"

  identifier = "${local.name}-${local.environment}"

  engine               = var.engine
  engine_version       = var.engine_version
  family               = var.family
  major_engine_version = var.major_engine_version
  instance_class       = var.instance_class

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage

  db_name  = var.database_name
  username = var.username
  port     = var.port

  multi_az               = var.environment == "prod"
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  maintenance_window              = "Mon:00:00-Mon:03:00"
  backup_window                   = "03:00-06:00"
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]
  create_cloudwatch_log_group     = true

  backup_retention_period = var.environment == "prod" ? 30 : 7
  skip_final_snapshot     = var.environment != "prod"
  deletion_protection     = true

  performance_insights_enabled          = true
  performance_insights_retention_period = 7
  create_monitoring_role                = true
  monitoring_interval                   = 60
  monitoring_role_name                  = "${local.name}-${local.environment}-rds-monitoring"
  monitoring_role_use_name_prefix       = true

  # Enable IAM authentication
  iam_database_authentication_enabled = true

  parameters = var.parameters

  tags = local.tags
}

resource "aws_db_subnet_group" "this" {
  name_prefix = "${local.name}-${local.environment}"
  subnet_ids  = data.aws_subnets.database.ids
  tags        = local.tags
}

# DNS Record
resource "aws_route53_record" "db" {
  count   = var.create_dns_record ? 1 : 0
  zone_id = var.route53_zone_id
  name    = "${var.dns_name}.${var.dns_zone_name}"
  type    = "CNAME"
  ttl     = 300
  records = [module.db.db_instance_address]
}

# Get VPC information
data "aws_vpc" "selected" {
  id = var.vpc_id
}
