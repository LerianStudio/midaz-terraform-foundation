provider "azurerm" {
  features {}
}

############################################
# IMPORT EXISTING SUBNETS/RG (VNet required) #
############################################

data "azurerm_virtual_network" "vnet" {
  name                = "midaz-vnet"
  resource_group_name = "lerian-terraform-rg"
}

data "azurerm_subnet" "subnet_aks_1" {
  name                 = "private-aks-subnet-1"
  virtual_network_name = data.azurerm_virtual_network.vnet.name
  resource_group_name  = "lerian-terraform-rg"
}

data "azurerm_subnet" "subnet_aks_2" {
  name                 = "private-aks-subnet-2"
  virtual_network_name = data.azurerm_virtual_network.vnet.name
  resource_group_name  = "lerian-terraform-rg"
}

data "azurerm_resource_group" "aks" {
  name = "lerian-terraform-rg"
}


############################################
# LOG ANALYTICS WORKSPACE FOR MONITORING  #
############################################

resource "azurerm_log_analytics_workspace" "aks" {
  name                = "log-aks-example"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.aks.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

##################################
#         AZURE AKS              #
##################################

resource "azurerm_kubernetes_cluster" "aks" {
  name                = var.cluster_name
  location            = data.azurerm_resource_group.aks.location
  resource_group_name = data.azurerm_resource_group.aks.name
  dns_prefix          = "aks-example"
  kubernetes_version  = var.kubernetes_version

  role_based_access_control_enabled = true

  network_profile {
  network_plugin    = "azure"
  network_policy    = "calico"
  
  # Defina o service CIDR para uma faixa que não colida
  service_cidr      = "10.240.0.0/16"  # Exemplo de faixa que provavelmente não colide

  # Opcional: o DNS CIDR do cluster — pode ajustar se precisar
  dns_service_ip    = "10.240.0.10"
}
  
  private_cluster_enabled              = true
  private_cluster_public_fqdn_enabled  = false
  private_dns_zone_id                  = "System"

  # Main node pool in subnet 1
  default_node_pool {
    name           = "default"
    node_count     = var.node_count
    vm_size        = var.node_vm_size
    vnet_subnet_id = data.azurerm_subnet.subnet_aks_1.id
  }

  # System-assigned managed identity for access to ACR, Key Vault, etc.
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

resource "azurerm_kubernetes_cluster_node_pool" "infra" {
  name                  = "infra"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.aks.id
  vm_size               = var.infra_node_vm_size
  node_count            = var.infra_node_count
  vnet_subnet_id        = data.azurerm_subnet.subnet_aks_2.id
  orchestrator_version  = var.kubernetes_version
  mode                  = "User"

  tags = var.tags
}