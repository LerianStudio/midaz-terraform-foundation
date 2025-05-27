provider "azurerm" {
  features {}
}

############################################
# LOG ANALYTICS WORKSPACE FOR MONITORING  #
############################################

resource "azurerm_log_analytics_workspace" "aks" {
  name                = var.log_analytics_workspace_name
  location            = var.location
  resource_group_name = data.azurerm_resource_group.aks.name
  sku                 = var.log_analytics_sku
  retention_in_days   = var.log_analytics_retention
  tags                = var.tags
}

##################################
#         AZURE AKS              #
##################################

resource "azurerm_kubernetes_cluster" "aks" {
  name                = var.cluster_name
  location            = data.azurerm_resource_group.aks.location
  resource_group_name = data.azurerm_resource_group.aks.name
  dns_prefix          = var.dns_prefix
  kubernetes_version  = var.kubernetes_version

  role_based_access_control_enabled = true

  network_profile {
    network_plugin = var.network_plugin
    network_policy = var.network_policy
    service_cidr   = var.service_cidr
    dns_service_ip = var.dns_service_ip
  }

  private_cluster_enabled = var.private_cluster_enabled

  default_node_pool {
    name           = var.default_node_pool_name
    node_count     = var.node_count
    vm_size        = var.node_vm_size
    vnet_subnet_id = data.azurerm_subnet.subnet_aks_1.id
  }

  identity {
    type = "SystemAssigned"
  }

  oms_agent {
    log_analytics_workspace_id = azurerm_log_analytics_workspace.aks.id
  }

  tags = var.tags
}

##################################
#     SECOND USER NODE POOL      #
##################################

resource "azurerm_kubernetes_cluster_node_pool" "armnp" {
  name                  = var.arm_node_pool_name
  kubernetes_cluster_id = azurerm_kubernetes_cluster.aks.id
  vm_size               = var.arm_node_vm_size
  os_type               = "Linux"
  orchestrator_version  = var.kubernetes_version
  node_count            = var.arm_node_count
  enable_auto_scaling   = true
  min_count             = var.arm_min_count
  max_count             = var.arm_max_count
  vnet_subnet_id        = data.azurerm_subnet.subnet_aks_2.id

  mode = "User"

  node_labels = {
    "architecture" = "arm64"
  }
  tags = var.tags
}
