#######################################################
# IMPORT EXISTING SUBNETS/RG/DNS ZONE (VNet required) #
#######################################################

data "azurerm_virtual_network" "vnet" {
  name                = "midaz-vnet"
  resource_group_name = "midaz-terraform-rg"
}

data "azurerm_resource_group" "dns" {
  name = var.resource_group_name
}
