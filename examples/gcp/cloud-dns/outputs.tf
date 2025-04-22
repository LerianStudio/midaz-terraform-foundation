output "dns_zone_name" {
  description = "The name of the DNS zone"
  value       = module.dns-private-zone.name
}

output "dns_zone_domain" {
  description = "The domain name of the DNS zone"
  value       = module.dns-private-zone.domain
}

output "name_servers" {
  description = "The DNS zone name servers"
  value       = module.dns-private-zone.name_servers
}
