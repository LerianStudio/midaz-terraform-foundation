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

output "auth_service_account" {
  description = "The service account used for Valkey authentication"
  value       = google_service_account.valkey_auth.email
}

output "auth_secret_name" {
  description = "The name of the secret containing the service account key"
  value       = google_secret_manager_secret.valkey_auth.name
}