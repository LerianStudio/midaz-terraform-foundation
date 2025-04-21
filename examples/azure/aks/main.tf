terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}
}

resource "azurerm_resource_group" "aks" {
  name     = "rg-aks-example"
  location = "eastus2"

  tags = {
    Environment = "Example"
    Terraform   = "true"
  }
}

resource "azurerm_kubernetes_cluster" "aks" {
  name                = "aks-cluster-example"
  location            = azurerm_resource_group.aks.location
  resource_group_name = azurerm_resource_group.aks.name
  dns_prefix          = "aks-example"
  kubernetes_version  = "1.26.0"

  default_node_pool {
    name       = "default"
    node_count = 2
    vm_size    = "Standard_D2s_v3"
  }

  identity {
    type = "SystemAssigned"
  }

  tags = {
    Environment = "Example"
    Terraform   = "true"
  }
}
