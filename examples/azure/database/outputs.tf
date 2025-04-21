output "server_id" {
  description = "The ID of the SQL Server"
  value       = azurerm_mssql_server.example.id
}

output "server_fqdn" {
  description = "The fully qualified domain name of the SQL Server"
  value       = azurerm_mssql_server.example.fully_qualified_domain_name
}

output "database_id" {
  description = "The ID of the SQL Database"
  value       = azurerm_mssql_database.example.id
}

output "database_connection_string" {
  description = "Connection string for the Azure SQL Database"
  value       = "Server=tcp:${azurerm_mssql_server.example.fully_qualified_domain_name},1433;Initial Catalog=${azurerm_mssql_database.example.name};Persist Security Info=False;User ID=${azurerm_mssql_server.example.administrator_login};Password=<your_password>;MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"
  sensitive   = true
}
