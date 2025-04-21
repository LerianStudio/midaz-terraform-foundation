terraform {
  backend "azurerm" {
    resource_group_name  = "<PUT-YOUR-RESOURCE-GROUP-NAME-HERE>"
    storage_account_name = "<PUT-YOUR-STORAGE-ACCOUNT-NAME-HERE>"
    container_name       = "terraform-state"
    key                  = "azure/dns/terraform.tfstate"
  }
}
