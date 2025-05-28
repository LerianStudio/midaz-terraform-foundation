# Generate RDS password
resource "random_password" "master" {
  length           = 16
  special          = true
  override_special = "!#$%^&*()-_=+[]{}<>:?"
}

# Store RDS credentials in AWS secrets manager
resource "aws_secretsmanager_secret" "rds" {
  name = "${var.name}/rds"

  tags = merge({
    Name        = "${var.name}-rds-secret"
    Environment = lower(var.environment)
    ManagedBy   = "Terraform"
  }, var.additional_tags)
}

resource "aws_secretsmanager_secret_version" "rds" {
  secret_id = aws_secretsmanager_secret.rds.id
  secret_string = jsonencode({
    username = var.username
    password = random_password.master.result
    engine   = var.engine
    host     = module.db.db_instance_address
    port     = var.port
    dbname   = var.database_name
  })
}
