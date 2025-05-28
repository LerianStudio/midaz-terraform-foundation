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