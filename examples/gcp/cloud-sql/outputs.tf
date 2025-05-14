output "instance_name" {
  description = "The name of the Cloud SQL instance"
  value       = module.postgresql.instance_name
}

output "private_ip_address" {
  description = "The private IP address of the Cloud SQL instance"
  value       = module.postgresql.private_ip_address
}

output "connection_name" {
  description = "The connection name of the instance to be used in connection strings"
  value       = module.postgresql.instance_connection_name
}

output "dns_record" {
  description = "The DNS record for PostgreSQL instance"
  value       = google_dns_record_set.database.name
}

output "replica_dns_record" {
  description = "The DNS record for PostgreSQL read replica instance"
  value       = var.high_availability ? google_dns_record_set.database_replica[0].name : null
}