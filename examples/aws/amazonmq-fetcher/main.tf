# Resource to generate a random password for the broker
resource "random_password" "master" {
  length           = 16
  special          = true
  override_special = "!#$%^&*()-_+{}<>?"
}

locals {
  # Detect if this is a cluster deployment
  is_cluster = var.deployment_mode == "CLUSTER_MULTI_AZ"

  # Add mode suffix to resource name for clarity
  mode_suffix = local.is_cluster ? "cluster" : "single"
  name        = "${var.name}-${local.mode_suffix}"

  # Group subnets by availability zone and pick one subnet per AZ
  # This ensures each selected subnet is in a different AZ for HA
  subnets_by_az = {
    for id, subnet in data.aws_subnet.private :
    subnet.availability_zone => id...
  }
  distinct_az_count = length(local.subnets_by_az)

  # Select one subnet per AZ (up to 3 for cluster mode)
  cluster_subnet_ids = slice(
    [for az, ids in local.subnets_by_az : ids[0]],
    0,
    min(local.distinct_az_count, 3)
  )

  # Subnet selection logic:
  # - SINGLE_INSTANCE: 1 subnet
  # - CLUSTER_MULTI_AZ: 2-3 subnets in different AZs (RabbitMQ supports up to 3)
  # Note: Using try() to avoid index-out-of-bounds before preconditions run
  subnet_ids = local.is_cluster ? local.cluster_subnet_ids : [try(data.aws_subnets.private.ids[0], null)]

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
  subnet_ids                 = local.subnet_ids
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

  # Validation preconditions
  lifecycle {
    precondition {
      condition     = var.deployment_mode != "ACTIVE_STANDBY_MULTI_AZ"
      error_message = "ACTIVE_STANDBY_MULTI_AZ is only supported for ActiveMQ. This module uses RabbitMQ - use CLUSTER_MULTI_AZ for high availability."
    }

    precondition {
      condition     = !(var.deployment_mode == "CLUSTER_MULTI_AZ" && can(regex("^mq\\.t3\\.", var.host_instance_type)))
      error_message = "CLUSTER_MULTI_AZ deployment mode does not support mq.t3.* instance types. Use mq.m5.large or larger."
    }

    precondition {
      condition     = !local.is_cluster || local.distinct_az_count >= 2
      error_message = "CLUSTER_MULTI_AZ deployment mode requires private subnets in at least 2 different availability zones. Found ${local.distinct_az_count} distinct AZ(s)."
    }

    precondition {
      condition     = length(data.aws_subnets.private.ids) > 0
      error_message = "No private subnets found. At least 1 private subnet is required for SINGLE_INSTANCE, or subnets in 2-3 different AZs for CLUSTER_MULTI_AZ."
    }
  }
}