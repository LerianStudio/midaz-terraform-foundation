variable "project_id" {
  description = "The GCP project ID"
  type        = string
}

variable "network_name" {
  description = "Name of the VPC network"
  type        = string
  default     = "midaz-network"
}

variable "region" {
  description = "The GCP region for the network"
  type        = string
}

variable "subnet_cidr" {
  description = "The CIDR range for the subnet (should be a /16)"
  type        = string
  default     = "10.0.0.0/16"
}

variable "pods_cidr_range" {
  description = "The CIDR range for GKE pods"
  type        = string
  default     = "10.1.0.0/16"
}

variable "services_cidr_range" {
  description = "The CIDR range for GKE services"
  type        = string
  default     = "10.2.0.0/16"
}
