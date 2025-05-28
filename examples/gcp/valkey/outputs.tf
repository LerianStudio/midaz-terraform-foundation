output "id" {
  description = "The Valkey cluster instance ID"
  value       = module.memorystore_valkey.id
}

output "discovery_endpoints" {
  description = "Endpoints created on each given network, for valkey clients to connect to the cluster"
  value       = module.memorystore_valkey.discovery_endpoints
}

output "dns_record" {
  description = "The DNS record for the Valkey instance"
  value       = google_dns_record_set.valkey.name
}
