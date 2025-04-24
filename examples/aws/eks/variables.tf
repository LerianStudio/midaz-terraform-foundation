variable "name" {
  description = "Base name for resources"
  type        = string
  default     = "midaz-foundation"
}

variable "environment" {
  description = "Deployment environment: dev, hml, or prod"
  type        = string
  default     = "dev"
}

variable "vpc_id" {
  description = "VPC ID where EKS cluster will be created"
  type        = string
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.27"
}

variable "cluster_endpoint_public_access" {
  description = "Enable public access to EKS cluster endpoint"
  type        = bool
  default     = false
}

variable "instance_types" {
  description = "List of EC2 instance types for node groups"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "min_size" {
  description = "Minimum number of nodes in node group"
  type        = number
  default     = 1
}

variable "max_size" {
  description = "Maximum number of nodes in node group"
  type        = number
  default     = 3
}

variable "desired_size" {
  description = "Desired number of nodes in node group"
  type        = number
  default     = 2
}

variable "capacity_type" {
  description = "Type of capacity associated with the EKS Node Group. Valid values: ON_DEMAND, SPOT"
  type        = string
  default     = "ON_DEMAND"
}

variable "additional_tags" {
  description = "Additional tags for resources"
  type        = map(string)
  default     = {}
}
