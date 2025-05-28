# RDS security group for VPC access
resource "aws_security_group" "rds" {
  name = "${var.name}-security-group-rds"

  description = "Security group for RDS instance"
  vpc_id      = data.aws_vpc.selected.id

  ingress {
    description = "Allow database port access"
    from_port   = var.port
    to_port     = var.port
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.selected.cidr_block]
  }

  tags = merge({
    Name        = "${var.name}-security-group-rds"
    Environment = lower(var.environment)
    ManagedBy   = "Terraform"
  }, var.additional_tags)
}

# RDS subnet group
resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-db-subnet-group"
  subnet_ids = data.aws_subnets.database.ids
  tags = merge({
    Environment = lower(var.environment)
    ManagedBy   = "Terraform"
  }, var.additional_tags)
}

# Primary RDS instance with monitoring and backups
module "db" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 6.0"

  identifier = var.name

  # Engine config
  engine               = var.engine
  engine_version       = var.engine_version
  family               = var.family
  major_engine_version = var.major_engine_version
  instance_class       = var.instance_class

  # Storage config
  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage

  # Database config
  db_name  = var.database_name
  username = var.username
  port     = var.port
  password = random_password.master.result

  # Not supported with replicas
  manage_master_user_password = false

  # Network config
  multi_az               = var.multi_az
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  # Maintenance and backup config
  maintenance_window              = var.maintenance_window
  backup_window                   = var.backup_window
  enabled_cloudwatch_logs_exports = var.enabled_cloudwatch_logs_exports
  create_cloudwatch_log_group     = var.create_cloudwatch_log_group
  backup_retention_period         = var.backup_retention_period
  skip_final_snapshot             = var.skip_final_snapshot
  deletion_protection             = var.deletion_protection

  # Monitoring config
  performance_insights_enabled          = var.performance_insights_enabled
  performance_insights_retention_period = var.performance_insights_retention_period
  create_monitoring_role                = var.create_monitoring_role
  monitoring_interval                   = var.monitoring_interval
  monitoring_role_name                  = "${var.name}-monitoring-role"
  monitoring_role_use_name_prefix       = false

  # Authentication config
  iam_database_authentication_enabled = true

  # Custom parameters
  parameters = var.parameters

  # Resource tags
  tags = merge({
    Name        = "${var.name}-security-group-rds"
    Environment = lower(var.environment)
    ManagedBy   = "Terraform"
  }, var.additional_tags)
}

# Read replica with monitoring and auto-replication
module "db_replica" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 6.0"
  count   = var.create_read_replica ? 1 : 0

  identifier = "${var.name}-replica"

  # Source config
  replicate_source_db = module.db.db_instance_arn

  # Engine config
  engine               = var.engine
  engine_version       = var.engine_version
  family               = var.family
  major_engine_version = var.major_engine_version

  # Instance config
  instance_class = var.read_replica_instance_class
  multi_az       = var.read_replica_multi_az

  # Network config
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  # Maintenance and backup config
  backup_retention_period = 0 # Primary handles backups
  skip_final_snapshot     = true

  parameters = var.parameters

  # Monitoring config
  performance_insights_enabled          = var.performance_insights_enabled
  performance_insights_retention_period = var.performance_insights_retention_period
  create_monitoring_role                = var.create_monitoring_role
  monitoring_interval                   = var.monitoring_interval
  monitoring_role_name                  = "${var.name}-replica-monitoring-role"
  monitoring_role_use_name_prefix       = false

  tags = merge({
    Name        = "${var.name}-replica"
    Environment = lower(var.environment)
    ManagedBy   = "Terraform"
    Type        = "read-replica"
  }, var.additional_tags)
}
