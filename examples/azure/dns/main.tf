provider "azurerm" {
  features {}
}

resource "azurerm_private_dns_zone" "main" {
  name                = var.dns_zone_name
  resource_group_name = data.azurerm_resource_group.dns.name

  tags = {
    environment = var.environment
    managed_by  = "terraform"
  }
}

resource "azurerm_private_dns_zone_virtual_network_link" "main" {
  name                  = "${var.dns_zone_name}-link"
  resource_group_name   = data.azurerm_resource_group.dns.name
  private_dns_zone_name = azurerm_private_dns_zone.main.name
  virtual_network_id    = data.azurerm_virtual_network.vnet.id
  registration_enabled  = true

  tags = {
    environment = var.environment
    managed_by  = "terraform"
  }
}
