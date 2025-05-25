# Azure region where resources will be created
variable "location" {
  description = "Azure region where resources will be created"
  type        = string
  default     = "eastus2"
}

# Name of the resource group that will hold the AKS and other resources
variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
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

# IP CIDRs allowed to access the AKS API server (if public access is enabled)
variable "api_server_access_cidrs" {
  description = "List of IP CIDR ranges that are allowed to access the AKS API server"
  type        = list(string)
  default     = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
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

# Optional: VM size for the user node pool (infra)
variable "infra_node_vm_size" {
  description = "VM size for the user (infra) node pool"
  type        = string
  default     = "Standard_D4s_v3"
}

# Optional: Number of nodes for the user node pool
variable "infra_node_count" {
  description = "Number of nodes in the user (infra) node pool"
  type        = number
  default     = 3
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
  default     = []  # empty by default; set in terraform.tfvars
}
