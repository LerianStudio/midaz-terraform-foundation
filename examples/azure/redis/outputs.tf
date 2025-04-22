output "redis_id" {
  description = "The ID of the Redis Cache"
  value       = azurerm_redis_cache.example.id
}

output "redis_hostname" {
  description = "The hostname of the Redis Cache"
  value       = azurerm_redis_cache.example.hostname
}

output "redis_ssl_port" {
  description = "The SSL port of the Redis Cache"
  value       = azurerm_redis_cache.example.ssl_port
}

output "redis_connection_string" {
  description = "Primary connection string for the Redis Cache"
  value       = azurerm_redis_cache.example.primary_connection_string
  sensitive   = true
}

output "redis_primary_key" {
  description = "Primary access key for the Redis Cache"
  value       = azurerm_redis_cache.example.primary_access_key
  sensitive   = true
}
