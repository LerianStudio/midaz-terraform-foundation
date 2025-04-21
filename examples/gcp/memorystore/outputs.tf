output "instance_name" {
  description = "The name of the Memorystore instance"
  value       = module.memorystore.instance_name
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
