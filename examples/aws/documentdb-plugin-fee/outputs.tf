output "cluster_id" {
  description = "The DocumentDB cluster ID for Plugin Fee."
  value       = aws_docdb_cluster.main.id
}

output "cluster_arn" {
  description = "The DocumentDB cluster ARN for Plugin Fee."
  value       = aws_docdb_cluster.main.arn
}

output "cluster_endpoint" {
  description = "The endpoint of the DocumentDB cluster for Plugin Fee."
  value       = aws_docdb_cluster.main.endpoint
}

output "cluster_reader_endpoint" {
  description = "The reader endpoint of the DocumentDB cluster for Plugin Fee."
  value       = aws_docdb_cluster.main.reader_endpoint
}

output "docdb_security_group_id" {
  description = "The ID of the security group for the DocumentDB cluster for Plugin Fee."
  value       = aws_security_group.docdb.id
}

output "docdb_password_secret_arn" {
  description = "The ARN of the secret containing the DocumentDB master password for Plugin Fee."
  value       = aws_secretsmanager_secret.docdb_password.arn
}
