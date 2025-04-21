output "dns_zone_name" {
  description = "The name of the DNS zone"
  value       = module.dns-private-zone.name
}

output "dns_zone_id" {
  description = "The ID of the DNS zone"
  value       = module.dns-private-zone.id
}

output "domain_name" {
  description = "The domain name of the DNS zone"
  value       = var.dns_domain
}
