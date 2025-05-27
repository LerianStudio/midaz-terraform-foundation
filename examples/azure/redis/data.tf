#######################################################
# IMPORT EXISTING SUBNETS/RG/DNS ZONE (VNet required) #
#######################################################

data "azurerm_virtual_network" "vnet" {
  name                = "midaz-vnet"
  resource_group_name = "lerian-terraform-rg"
}

data "azurerm_subnet" "subnet_redis_1" {
  name                 = "private-redis-subnet-1"
  virtual_network_name = data.azurerm_virtual_network.vnet.name
  resource_group_name  = "lerian-terraform-rg"
}

data "azurerm_subnet" "subnet_redis_2" {
  name                 = "private-redis-subnet-2"
  virtual_network_name = data.azurerm_virtual_network.vnet.name
  resource_group_name  = "lerian-terraform-rg"
}

data "azurerm_resource_group" "redis" {
  name = var.resource_group_name
}

data "azurerm_private_dns_zone" "redis" {
  name                = var.dns_zone_name
  resource_group_name = var.resource_group_name
}