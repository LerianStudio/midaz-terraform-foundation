#######################################################
# IMPORT EXISTING SUBNETS/RG/DNS ZONE (VNet required) #
#######################################################

data "azurerm_virtual_network" "vnet" {
  name                = "midaz-vnet"
  resource_group_name = "lerian-terraform-rg"
}

data "azurerm_subnet" "subnet_db_1" {
  name                 = "private-db-subnet-1"
  virtual_network_name = data.azurerm_virtual_network.vnet.name
  resource_group_name  = "lerian-terraform-rg"
}

data "azurerm_subnet" "subnet_db_2" {
  name                 = "private-db-subnet-2"
  virtual_network_name = data.azurerm_virtual_network.vnet.name
  resource_group_name  = "lerian-terraform-rg"
}

data "azurerm_resource_group" "db" {
  name = "lerian-terraform-rg"
}