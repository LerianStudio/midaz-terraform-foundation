output "dns_zone_id" {
  description = "The ID of the Private DNS Zone"
  value       = azurerm_private_dns_zone.main.id
}

output "dns_zone_name" {
  description = "The name of the Private DNS Zone"
  value       = azurerm_private_dns_zone.main.name
}

output "vnet_link_id" {
  description = "The ID of the Private DNS Zone Virtual Network Link"
  value       = azurerm_private_dns_zone_virtual_network_link.main.id
}

output "a_records" {
  description = "Map of A records created"
  value       = { for k, v in azurerm_private_dns_a_record.records : k => v.fqdn }
}

output "cname_records" {
  description = "Map of CNAME records created"
  value       = { for k, v in azurerm_private_dns_cname_record.records : k => v.fqdn }
}

output "mx_records" {
  description = "Map of MX records created"
  value       = { for k, v in azurerm_private_dns_mx_record.records : k => v.fqdn }
}

output "txt_records" {
  description = "Map of TXT records created"
  value       = { for k, v in azurerm_private_dns_txt_record.records : k => v.fqdn }
}
