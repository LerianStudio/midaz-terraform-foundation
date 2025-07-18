# Security group for Valkey cluster
resource "aws_security_group" "valkey" {
  name_prefix = "${var.name}-valkey-"
  description = "Security group for Valkey cluster"
  vpc_id      = data.aws_vpc.selected.id

  tags = merge({
    Name        = "${var.name}-valkey"
    Environment = lower(var.environment)
    ManagedBy   = "Terraform"
  }, var.additional_tags)
}

# Valkey cluster using official AWS module
module "valkey" {
  source  = "terraform-aws-modules/elasticache/aws"
  version = "~> 1.6.0"

  replication_group_id = var.name

  # Engine configuration
  engine         = "valkey"
  engine_version = var.engine_version
  node_type      = var.node_type

  # Network configuration
  vpc_id = data.aws_vpc.selected.id
  security_group_rules = {
    ingress_vpc = {
      description = "VPC traffic"
      cidr_ipv4   = data.aws_vpc.selected.cidr_block
    }
  }

  # Subnet Group
  subnet_group_name        = var.name
  subnet_group_description = "${title(var.name)} subnet group"
  subnet_ids               = data.aws_subnets.cache.ids

  # Parameter Group
  create_parameter_group      = true
  parameter_group_name        = var.name
  parameter_group_family      = var.parameter_group_family
  parameter_group_description = "${title(var.name)} parameter group"
  parameters                  = var.parameters

  # Security
  transit_encryption_enabled = var.transit_encryption_enabled

  # transit_encryption_mode and auth_token will be used once Midaz accepts TLS certificates configuration
  transit_encryption_mode = var.transit_encryption_mode
  #auth_token                 = random_password.valkey_auth.result

  # Maintenance
  maintenance_window = var.maintenance_window
  apply_immediately  = var.apply_immediately

  # Tags
  tags = merge({
    Name        = "${var.name}-valkey"
    Environment = lower(var.environment)
    ManagedBy   = "Terraform"
  }, var.additional_tags)
}
