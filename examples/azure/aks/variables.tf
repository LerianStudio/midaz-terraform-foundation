variable "location" {
  description = "Azure region where resources will be created"
  type        = string
  default     = "eastus2"
}

variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
  default     = "rg-aks-example"
}

variable "cluster_name" {
  description = "Name of the AKS cluster"
  type        = string
  default     = "aks-cluster-example"
}

variable "kubernetes_version" {
  description = "Version of Kubernetes to use"
  type        = string
  default     = "1.26.0"
}

variable "node_count" {
  description = "Number of nodes in the default node pool"
  type        = number
  default     = 2
}

variable "node_vm_size" {
  description = "Size of the VM for nodes"
  type        = string
  default     = "Standard_D2s_v3"
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default = {
    Environment = "Example"
    Terraform   = "true"
  }
}
