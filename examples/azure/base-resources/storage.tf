provider "azurerm" {
  features {}
  subscription_id = "d4c48709-7f36-448a-a558-4a0f5229a119"  # Adicionando a subscription_id
}

resource "azurerm_resource_group" "tf_backend_rg" {
  name     = "lerian-terraform-rg"
  location = "East US"
}

resource "azurerm_storage_account" "tf_state_sa" {
  name                     = "lerianterraformstate" # precisa ser único globalmente
  resource_group_name      = azurerm_resource_group.tf_backend_rg.name
  location                 = azurerm_resource_group.tf_backend_rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_storage_container" "tf_state_container" {
  name                  = "terraform-state"
  storage_account_name  = azurerm_storage_account.tf_state_sa.name
  container_access_type = "private"
}
