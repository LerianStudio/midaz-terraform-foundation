data "azurerm_subnet" "subnet_cosmosdb_1" {
  name                 = "private-cosmos-subnet-1"
  virtual_network_name = data.azurerm_virtual_network.vnet.name
  resource_group_name  = data.azurerm_resource_group.cosmosdb.name
}

data "azurerm_subnet" "subnet_cosmosdb_2" {
  name                 = "private-cosmos-subnet-2"
  virtual_network_name = data.azurerm_virtual_network.vnet.name
  resource_group_name  = data.azurerm_resource_group.cosmosdb.name
}
data "azurerm_virtual_network" "vnet" {
  name                = "midaz-vnet"
  resource_group_name = "midaz-terraform-rg"
}
data "azurerm_resource_group" "cosmosdb" {
  name = "midaz-terraform-rg"
}