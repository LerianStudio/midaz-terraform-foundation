# Resource to generate a random password for the broker
resource "random_password" "master" {
  length           = 16
  special          = true
  override_special = "!#$%^&*()-_+{}<>?"
}

locals {
  name = var.name
  tags = merge(
    {
      "Name"        = local.name
      "Environment" = var.environment
    },
    var.additional_tags
  )
}

# Create a new secret for the MQ admin password
resource "aws_secretsmanager_secret" "mq_password" {
  name = "${local.name}/amazonmq-password"
  tags = local.tags
}

resource "aws_secretsmanager_secret_version" "mq_password" {
  secret_id     = aws_secretsmanager_secret.mq_password.id
  secret_string = random_password.master.result
}

# Security group for the AmazonMQ broker
resource "aws_security_group" "mq" {
  name        = "${local.name}-sg"
  description = "Allow traffic to AmazonMQ broker"
  vpc_id      = data.aws_vpc.selected.id

  tags = local.tags
}

resource "aws_vpc_security_group_ingress_rule" "mq" {
  security_group_id = aws_security_group.mq.id
  description       = "Allow traffic to AmazonMQ broker"
  cidr_ipv4         = data.aws_vpc.selected.cidr_block
  ip_protocol       = "-1"
}

# Main AmazonMQ broker configuration
resource "aws_mq_broker" "main" {
  broker_name                = local.name
  deployment_mode            = var.deployment_mode
  engine_type                = var.engine_type
  engine_version             = var.engine_version
  host_instance_type         = var.host_instance_type
  publicly_accessible        = var.publicly_accessible
  auto_minor_version_upgrade = var.auto_minor_version_upgrade
  subnet_ids                 = [data.aws_subnets.private.ids[0]]
  security_groups            = [aws_security_group.mq.id]

  user {
    username = var.mq_admin_user
    password = aws_secretsmanager_secret_version.mq_password.secret_string
  }

  tags = local.tags

  # Apply changes immediately
  apply_immediately = true

  # Enable general and audit logs
  logs {
    general = true
  }
}
