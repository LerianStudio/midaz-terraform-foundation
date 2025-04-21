provider "azurerm" {
  features {}
}

resource "azurerm_log_analytics_workspace" "aks" {
  name                = "log-aks-example"
  location            = "eastus2"
  resource_group_name = azurerm_resource_group.aks.name
  sku                 = "PerGB2018"
  retention_in_days   = 30

  tags = {
    Environment = "Example"
    Terraform   = "true"
  }
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

  role_based_access_control_enabled = true

  network_profile {
    network_plugin = "azure"
    network_policy = "calico"
  }

  private_cluster_enabled             = true
  private_cluster_public_fqdn_enabled = false
  private_dns_zone_id                 = "System"

  api_server_access_profile {
    authorized_ip_ranges = var.api_server_access_cidrs
  }

  default_node_pool {
    name       = "default"
    node_count = 2
    vm_size    = "Standard_D2s_v3"
  }

  identity {
    type = "SystemAssigned"
  }

  oms_agent {
    log_analytics_workspace_id = azurerm_log_analytics_workspace.aks.id
  }

  tags = {
    Environment = "Example"
    Terraform   = "true"
  }
}
