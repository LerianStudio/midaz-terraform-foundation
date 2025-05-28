

output "db_instance_arn" {
  description = "The ARN of the RDS instance"
  value       = module.db.db_instance_arn
}

output "db_instance_name" {
  description = "The database name"
  value       = module.db.db_instance_name
}

output "db_instance_port" {
  description = "The database port"
  value       = module.db.db_instance_port
}

output "db_subnet_group_id" {
  description = "The db subnet group name"
  value       = aws_db_subnet_group.this.id
}

output "db_security_group_id" {
  description = "The security group ID"
  value       = aws_security_group.rds.id
}

output "read_replica_arn" {
  description = "The ARN of the RDS read replica instance"
  value       = try(module.db_replica[0].db_instance_arn, null)
}

output "read_replica_name" {
  description = "The database name of the read replica"
  value       = try(module.db_replica[0].db_instance_name, null)
}

output "read_replica_port" {
  description = "The database port of the read replica"
  value       = try(module.db_replica[0].db_instance_port, null)
}

output "db_dns_name" {
  description = "The DNS name for the primary database"
  value       = aws_route53_record.db.name
}

output "read_replica_dns_name" {
  description = "The DNS name for the read replica"
  value       = try(aws_route53_record.db_replica[0].name, null)
}

output "db_secret_name" {
  description = "The name of the Secrets Manager secret storing the database credentials"
  value       = aws_secretsmanager_secret.rds.name
}

output "db_secret_arn" {
  description = "The ARN of the Secrets Manager secret storing the database credentials"
  value       = aws_secretsmanager_secret.rds.arn
}