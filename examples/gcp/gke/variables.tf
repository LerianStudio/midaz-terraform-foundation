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

variable "ip_range_pods" {
  description = "The secondary IP range name for pods"
  type        = string
  default     = "pods"
}

variable "ip_range_services" {
  description = "The secondary IP range name for services"
  type        = string
  default     = "services"
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
  default = [
    {
      cidr_block   = "10.0.0.0/8"
      display_name = "internal-vpc"
    }
  ]
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

variable "environment" {
  description = "Environment name for resource labels"
  type        = string
  default     = "production"
}

variable "network_policy_enabled" {
  description = "Enable network policy (Calico)"
  type        = bool
  default     = false
}

variable "pod_security_policy_enabled" {
  description = "Enable pod security policy"
  type        = bool
  default     = false
}

variable "datapath_provider" {
  description = "The desired datapath provider for the cluster"
  type        = string
  default     = "ADVANCED_DATAPATH"
}

variable "release_channel" {
  description = "The release channel of this cluster"
  type        = string
  default     = "REGULAR"
}

variable "node_disk_type" {
  description = "Type of the disk attached to each node"
  type        = string
  default     = "pd-ssd"
}

variable "node_image_type" {
  description = "The image type to use for nodes"
  type        = string
  default     = "COS_CONTAINERD"
}

variable "node_auto_repair" {
  description = "Whether the nodes will be automatically repaired"
  type        = bool
  default     = true
}

variable "node_auto_upgrade" {
  description = "Whether the nodes will be automatically upgraded"
  type        = bool
  default     = true
}

variable "node_preemptible" {
  description = "Whether to use preemptible nodes"
  type        = bool
  default     = false
}
