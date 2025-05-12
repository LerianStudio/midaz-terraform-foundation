terraform {
  backend "azurerm" {
    resource_group_name  = "lerian-terraform-rg" # Change for your resource group name
    storage_account_name = "lerianterraformstate" #Change for your storage account name
    container_name       = "terraform-state"
    key                  = "azure/dns/terraform.tfstate"
  }
}