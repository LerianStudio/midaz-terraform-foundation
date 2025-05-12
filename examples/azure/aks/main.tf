provider "azurerm" {
  features {}
}

resource "azurerm_log_analytics_workspace" "aks" {
  name                = "log-aks-example"
  location            = "eastus2"
  resource_group_name = azurerm_resource_group.aks.name
  sku                 = "PerGB2018"
  retention_in_days   = 30

  tags = var.tags
}

resource "azurerm_resource_group" "aks" {
  name     = var.resource_group_name
  location = var.location

  tags = var.tags
}

resource "azurerm_kubernetes_cluster" "aks" {
  name                = var.cluster_name
  location            = azurerm_resource_group.aks.location
  resource_group_name = azurerm_resource_group.aks.name
  dns_prefix          = "aks-example"
  kubernetes_version  = var.kubernetes_version

  role_based_access_control_enabled = true

  network_profile {
    network_plugin = "azure"
    network_policy = "calico"
  }

  private_cluster_enabled             = true
  private_cluster_public_fqdn_enabled = false
  private_dns_zone_id                 = "System"

  # api_server_access_profile {
  #   authorized_ip_ranges = var.api_server_access_cidrs
  # }

  default_node_pool {
    name       = "default"
    node_count = var.node_count
    vm_size    = var.node_vm_size
  }

  identity {
    type = "SystemAssigned"
  }

  oms_agent {
    log_analytics_workspace_id = azurerm_log_analytics_workspace.aks.id
  }

  tags = var.tags
}
