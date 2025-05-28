############################################
# IMPORT EXISTING SUBNETS/RG (VNet required)
############################################

data "azurerm_virtual_network" "vnet" {
  name                = "midaz-vnet"
  resource_group_name = "midaz-terraform-rg"
}

data "azurerm_subnet" "subnet_aks_1" {
  name                 = "private-aks-subnet-1"
  virtual_network_name = data.azurerm_virtual_network.vnet.name
  resource_group_name  = "midaz-terraform-rg"
}

data "azurerm_subnet" "subnet_aks_2" {
  name                 = "private-aks-subnet-2"
  virtual_network_name = data.azurerm_virtual_network.vnet.name
  resource_group_name  = "midaz-terraform-rg"
}

data "azurerm_resource_group" "aks" {
  name = "midaz-terraform-rg"
}
