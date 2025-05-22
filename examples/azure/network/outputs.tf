output "vnet_name" {
  description = "The name of the virtual network"
  value       = module.vnet.vnet_name
}

output "vnet_id" {
  description = "The id of the virtual network"
  value       = module.vnet.vnet_id
}

output "vnet_location" {
  description = "The location of the virtual network"
  value       = module.vnet.vnet_location
}

output "public_subnet_ids" {
  description = "The IDs of the public subnets"
  value       = slice(module.vnet.vnet_subnets, 0, length(var.public_subnet_prefixes))
}

output "private_aks_subnet_ids" {
  description = "The IDs of the private AKS subnets"
  value = slice(
    module.vnet.vnet_subnets,
    length(var.public_subnet_prefixes),
    min(
      length(module.vnet.vnet_subnets),
      length(var.public_subnet_prefixes) + length(var.private_aks_subnet_prefixes)
    )
  )
}

output "private_db_subnet_ids" {
  description = "The IDs of the private database subnets"
  value = slice(
    module.vnet.vnet_subnets,
    length(var.public_subnet_prefixes) + length(var.private_aks_subnet_prefixes),
    min(
      length(module.vnet.vnet_subnets),
      length(var.public_subnet_prefixes) + length(var.private_aks_subnet_prefixes) + length(var.private_db_subnet_prefixes)
    )
  )
}

output "public_nsg_id" {
  description = "The ID of the public network security group"
  value       = azurerm_network_security_group.public.id
}

output "private_nsg_id" {
  description = "The ID of the private network security group"
  value       = azurerm_network_security_group.private.id
}