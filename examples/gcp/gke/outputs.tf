output "cluster_name" {
  description = "The name of the cluster"
  value       = module.gke.name
}

output "cluster_endpoint" {
  description = "The IP address of the cluster master"
  value       = module.gke.endpoint
  sensitive   = true
}

output "cluster_ca_certificate" {
  description = "The public certificate that is the root of trust for the cluster"
  value       = module.gke.ca_certificate
  sensitive   = true
}

output "service_account" {
  description = "The service account used for the cluster"
  value       = var.service_account
}

output "network_tags" {
  description = "Network tags for the GKE nodes"
  value       = module.gke.node_pools_tags
}

output "cluster_location" {
  description = "The location of the cluster"
  value       = module.gke.location
}
