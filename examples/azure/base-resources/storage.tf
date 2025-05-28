resource "azurerm_resource_group" "tf_backend_rg" {
  provider = azurerm.sponsorship
  name     = "midaz-terraform-rg"
  location = "North Central US"
}

resource "azurerm_storage_account" "tf_state_sa" {
  provider                 = azurerm.sponsorship
  name                     = "leriansptfstate" # precisa ser único globalmente
  resource_group_name      = azurerm_resource_group.tf_backend_rg.name
  location                 = azurerm_resource_group.tf_backend_rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"
}

resource "azurerm_storage_container" "tf_state_container" {
  provider              = azurerm.sponsorship
  name                  = "terraform-state"
  storage_account_name  = azurerm_storage_account.tf_state_sa.name
  container_access_type = "private"
}