output "instance_id" {
  description = "The memorystore instance ID"
  value       = module.memorystore.id
}

output "host" {
  description = "The IP address of the instance"
  value       = module.memorystore.host
}

output "port" {
  description = "The port number of the instance"
  value       = module.memorystore.port
}

output "current_location_id" {
  description = "The current zone where the Redis endpoint is placed"
  value       = module.memorystore.current_location_id
}

output "env_vars" {
  description = "Environment variables for Redis connection"
  value       = module.memorystore.env_vars
}
