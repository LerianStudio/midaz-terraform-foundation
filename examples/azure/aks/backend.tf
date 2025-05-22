terraform {
  backend "azurerm" {
    resource_group_name  = "lerian-terraform-rg"
    storage_account_name = "leriansptfstate"
    container_name       = "terraform-state"
    key                  = "azure/aks/terraform.tfstate"
  }
}
