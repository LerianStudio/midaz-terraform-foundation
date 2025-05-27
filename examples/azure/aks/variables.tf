# Azure region where resources will be created
variable "location" {
  description = "Azure region where resources will be created"
  type        = string
  default     = "eastus2"
}

# Name of the AKS cluster
variable "cluster_name" {
  description = "Name of the AKS cluster"
  type        = string
}

# Kubernetes version to be used in the AKS cluster and node pools
variable "kubernetes_version" {
  description = "Version of Kubernetes to use"
  type        = string
}

# Number of nodes in the default (system) node pool
variable "node_count" {
  description = "Number of nodes in the default node pool"
  type        = number
  default     = 2
}

# Size of the VMs used in the default node pool
variable "node_vm_size" {
  description = "Size of the VM for nodes"
  type        = string
  default     = "Standard_D2s_v3"
}

# Tags to be applied to all resources
variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default = {
    Environment = "Example"
    Terraform   = "true"
  }
}

variable "authorized_ip_ranges" {
  description = "List of IP addresses allowed to access the AKS API server"
  type        = list(string)
  default     = [] # empty by default; set in terraform.tfvars
}

variable "log_analytics_workspace_name" {
  description = "Name of the Log Analytics Workspace"
  type        = string
  default     = "log-aks-example"
}

variable "log_analytics_sku" {
  description = "SKU for the Log Analytics Workspace"
  type        = string
  default     = "PerGB2018"
}

variable "log_analytics_retention" {
  description = "Retention in days for the Log Analytics Workspace"
  type        = number
  default     = 30
}

variable "dns_prefix" {
  description = "DNS prefix for the AKS cluster"
  type        = string
  default     = "aks-example"
}

variable "network_plugin" {
  description = "Network plugin used in AKS"
  type        = string
  default     = "azure"
}

variable "network_policy" {
  description = "Network policy for AKS"
  type        = string
  default     = "calico"
}

variable "service_cidr" {
  description = "CIDR for AKS services"
  type        = string
  default     = "10.240.0.0/16"
}

variable "dns_service_ip" {
  description = "DNS service IP"
  type        = string
  default     = "10.240.0.10"
}

variable "private_cluster_enabled" {
  description = "Whether the AKS cluster should be private"
  type        = bool
  default     = false
}

variable "default_node_pool_name" {
  description = "Name of the default node pool"
  type        = string
  default     = "default"
}

variable "arm_node_pool_name" {
  description = "Name of the ARM-based node pool"
  type        = string
  default     = "armnp"
}

variable "arm_node_vm_size" {
  description = "VM size for ARM node pool"
  type        = string
  default     = "Standard_D4ps_v5"
}

variable "arm_node_count" {
  description = "Initial node count for ARM node pool"
  type        = number
  default     = 1
}

variable "arm_min_count" {
  description = "Minimum autoscaling count for ARM node pool"
  type        = number
  default     = 1
}

variable "arm_max_count" {
  description = "Maximum autoscaling count for ARM node pool"
  type        = number
  default     = 3
}
