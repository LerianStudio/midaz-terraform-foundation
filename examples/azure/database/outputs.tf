output "primary_postgresql_server_id" {
  description = "The resource ID of the primary PostgreSQL Flexible Server"
  value       = azurerm_postgresql_flexible_server.primary.id
}

output "primary_postgresql_server_fqdn" {
  description = "The fully qualified domain name (FQDN) of the primary PostgreSQL server"
  value       = azurerm_postgresql_flexible_server.primary.fqdn
}

output "postgresql_read_replica_id" {
  description = "The resource ID of the PostgreSQL read replica (if enabled)"
  value       = length(azurerm_postgresql_flexible_server.replica) > 0 ? azurerm_postgresql_flexible_server.replica[0].id : null
}

output "postgresql_read_replica_fqdn" {
  description = "The FQDN of the PostgreSQL read replica (if enabled)"
  value       = length(azurerm_postgresql_flexible_server.replica) > 0 ? azurerm_postgresql_flexible_server.replica[0].fqdn : null
}
