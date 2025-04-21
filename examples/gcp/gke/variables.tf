variable "project_id" {
  description = "The GCP project ID"
  type        = string
}

variable "cluster_name" {
  description = "The name of the GKE cluster"
  type        = string
  default     = "midaz-cluster"
}

variable "region" {
  description = "The region for the GKE cluster"
  type        = string
}

variable "zones" {
  description = "The zones for the GKE cluster"
  type        = list(string)
}

variable "network_name" {
  description = "The name of the VPC network"
  type        = string
}

variable "subnet_name" {
  description = "The name of the subnet"
  type        = string
}

variable "master_ipv4_cidr_block" {
  description = "The IP range for the master network"
  type        = string
  default     = "172.16.0.0/28"
}

variable "enable_private_endpoint" {
  description = "Whether to enable private endpoint for the master"
  type        = bool
  default     = false
}

variable "master_authorized_networks" {
  description = "List of master authorized networks"
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  default = []
}

variable "machine_type" {
  description = "The machine type for the GKE nodes"
  type        = string
  default     = "e2-standard-2"
}

variable "min_node_count" {
  description = "Minimum number of nodes per zone"
  type        = number
  default     = 1
}

variable "max_node_count" {
  description = "Maximum number of nodes per zone"
  type        = number
  default     = 3
}

variable "initial_node_count" {
  description = "Initial number of nodes per zone"
  type        = number
  default     = 1
}

variable "disk_size_gb" {
  description = "Size of the disk attached to each node"
  type        = number
  default     = 100
}

variable "service_account" {
  description = "The service account to be used by the nodes"
  type        = string
}

variable "environment" {
  description = "Environment name for resource labels"
  type        = string
  default     = "production"
}
