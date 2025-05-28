output "replication_group_arn" {
  description = "ARN of the created ElastiCache Replication Group"
  value       = module.valkey.replication_group_arn
}

output "replication_group_id" {
  description = "ID of the ElastiCache Replication Group"
  value       = module.valkey.replication_group_id
}

output "replication_group_primary_endpoint_address" {
  description = "Address of the endpoint for the primary node in the replication group"
  value       = module.valkey.replication_group_primary_endpoint_address
}

output "replication_group_reader_endpoint_address" {
  description = "Address of the endpoint for the reader node in the replication group"
  value       = module.valkey.replication_group_reader_endpoint_address
}

output "replication_group_engine_version_actual" {
  description = "The running version of the cache engine"
  value       = module.valkey.replication_group_engine_version_actual
}

output "replication_group_member_clusters" {
  description = "Identifiers of all the nodes that are part of this replication group"
  value       = module.valkey.replication_group_member_clusters
}

output "parameter_group_arn" {
  description = "The AWS ARN associated with the parameter group"
  value       = module.valkey.parameter_group_arn
}

output "parameter_group_id" {
  description = "The ElastiCache parameter group name"
  value       = module.valkey.parameter_group_id
}

output "security_group_id" {
  description = "ID of the security group"
  value       = aws_security_group.valkey.id
}

output "security_group_arn" {
  description = "Amazon Resource Name (ARN) of the security group"
  value       = aws_security_group.valkey.arn
}

output "auth_secret_arn" {
  description = "ARN of the auth token secret in AWS Secrets Manager"
  value       = aws_secretsmanager_secret.valkey_auth.arn
}
