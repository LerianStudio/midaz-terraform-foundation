variable "name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "midaz-eks"
}

variable "environment" {
  description = "Environment name for the EKS cluster"
  type        = string
  default     = "<environment>"
}

variable "cluster_version" {
  description = "Kubernetes version to use for the EKS cluster"
  type        = string
  default     = "1.32"
}

variable "cluster_endpoint_public_access" {
  description = "Whether the Amazon EKS public API server endpoint is enabled"
  type        = bool
  default     = false
}

variable "allowed_api_access_cidrs" {
  description = "List of CIDR blocks that can access the Amazon EKS public API server endpoint"
  type        = list(string)
  default     = []
}

variable "instance_types" {
  description = <<-EOT
    List of instance types for the EKS managed node group. Based on TPS requirements:
    ARM (21-37% better performance):
    - Low TPS (<500): c7g.large
    - Medium TPS (500-1500): c7g.xlarge
    - High TPS (>1500): c7g.2xlarge

    x86_64:
    - Low TPS (<500): c6i.large
    - Medium TPS (500-1500): c6i.xlarge
    - High TPS (>1500): c6i.2xlarge
  EOT
  type        = list(string)
  default     = ["c7g.large"]
  validation {
    condition     = length([for type in var.instance_types : type if contains(["c7g.large", "c7g.xlarge", "c7g.2xlarge", "c6i.large", "c6i.xlarge", "c6i.2xlarge"], type)]) == length(var.instance_types)
    error_message = "ARM instances allowed: c7g.large, c7g.xlarge, c7g.2xlarge (recommended for 21-37% better performance)\nx86_64 instances allowed: c6i.large, c6i.xlarge, c6i.2xlarge"
  }
}

variable "min_size" {
  description = "Minimum number of nodes in the EKS managed node group"
  type        = number
  default     = 1
}

variable "max_size" {
  description = "Maximum number of nodes in the EKS managed node group"
  type        = number
  default     = 3
}

variable "desired_size" {
  description = "Desired number of nodes in the EKS managed node group"
  type        = number
  default     = 2
}

variable "capacity_type" {
  description = "Type of capacity associated with the EKS Node Group. Valid values: ON_DEMAND, SPOT"
  type        = string
  default     = "ON_DEMAND"
}

variable "additional_tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "vpc_name" {
  description = "Name of the VPC where the EKS cluster will be created"
  type        = string
}

variable "cluster_endpoint_private_access" {
  description = "Whether the Amazon EKS private API server endpoint is enabled"
  type        = bool
  default     = true
}

variable "enable_cluster_creator_admin_permissions" {
  description = "Indicates whether the cluster creator automatically receives admin permissions"
  type        = bool
  default     = true
}

variable "create_autoscaler_role" {
  description = "Whether to create the cluster autoscaler IAM role"
  type        = bool
  default     = true
}

variable "create_load_balancer_controller_role" {
  description = "Whether to create the AWS Load Balancer Controller IAM role"
  type        = bool
  default     = true
}

variable "attach_cluster_primary_security_group" {
  description = "Indicates whether the EKS managed node group should attach to the cluster primary security group"
  type        = bool
  default     = true
}

variable "create_security_group" {
  description = "Determines if a security group should be created for the EKS managed node group"
  type        = bool
  default     = false
}

variable "ami_type" {
  description = "Type of Amazon Machine Image (AMI) associated with the EKS Node Group"
  type        = string
  default     = "AL2_ARM_64"
  validation {
    condition     = contains(["AL2_x86_64", "AL2_x86_64_GPU", "AL2_ARM_64", "BOTTLEROCKET_x86_64", "BOTTLEROCKET_ARM_64", "WINDOWS_CORE_2019_x86_64", "WINDOWS_FULL_2019_x86_64", "WINDOWS_CORE_2022_x86_64", "WINDOWS_FULL_2022_x86_64"], var.ami_type)
    error_message = "AMI type must be one of: AL2_x86_64, AL2_x86_64_GPU, AL2_ARM_64, BOTTLEROCKET_x86_64, BOTTLEROCKET_ARM_64, WINDOWS_CORE_2019_x86_64, WINDOWS_FULL_2019_x86_64, WINDOWS_CORE_2022_x86_64, WINDOWS_FULL_2022_x86_64"
  }
}
