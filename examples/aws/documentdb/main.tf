# Resource to generate a random password for the master user
resource "random_password" "master" {
  length           = 16
  special          = true
  override_special = "!#$^&*()-_=+[]{}<>?"
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

# Create a new secret for the DocumentDB master password
resource "aws_secretsmanager_secret" "docdb_password" {
  name = "${local.name}/documentdb-password"
  tags = local.tags
}

resource "aws_secretsmanager_secret_version" "docdb_password" {
  secret_id     = aws_secretsmanager_secret.docdb_password.id
  secret_string = random_password.master.result
}

# DocumentDB subnet group
resource "aws_docdb_subnet_group" "main" {
  name       = "${local.name}-subnet-group"
  subnet_ids = data.aws_subnets.private.ids

  tags = local.tags
}

# Security group for the DocumentDB cluster
resource "aws_security_group" "docdb" {
  name        = "${local.name}-sg"
  description = "Allow traffic to DocumentDB cluster"
  vpc_id      = data.aws_vpc.selected.id

  # Allow inbound traffic on the DocumentDB port from within the VPC
  ingress {
    from_port   = 27017
    to_port     = 27017
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.selected.cidr_block]
  }

  tags = local.tags
}

resource "aws_docdb_cluster_parameter_group" "example" {
  family      = "docdb5.0"
  name        = "example"
  description = "docdb cluster parameter group"

  parameter {
    name  = "tls"
    value = var.documentdb_tls
  }

  tags = local.tags
}

# Main DocumentDB cluster configuration
resource "aws_docdb_cluster" "main" {
  cluster_identifier              = local.name
  engine                          = "docdb"
  master_username                 = var.master_username
  master_password                 = aws_secretsmanager_secret_version.docdb_password.secret_string
  db_subnet_group_name            = aws_docdb_subnet_group.main.name
  vpc_security_group_ids          = [aws_security_group.docdb.id]
  skip_final_snapshot             = true
  backup_retention_period         = var.backup_retention_period
  preferred_backup_window         = var.preferred_backup_window
  db_cluster_parameter_group_name = aws_docdb_cluster_parameter_group.example.name

  tags = local.tags
}

# DocumentDB cluster instances
resource "aws_docdb_cluster_instance" "main" {
  count              = var.instances_count
  identifier         = "${local.name}-instance-${count.index}"
  cluster_identifier = aws_docdb_cluster.main.id
  instance_class     = var.instance_class

  tags = local.tags
}