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

output "server_ca_cert" {
  description = "The CA certificate information used to connect to the SQL instance via SSL"
  value       = module.postgresql.instance_server_ca_cert
  sensitive   = true
}
