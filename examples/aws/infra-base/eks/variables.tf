################################################################################
# Identity and naming
#
# There is no `name` variable. Every resource name in this stack is derived from
# module.naming, so dev/stg/prd can live in the same AWS account without
# colliding on cluster names, IAM role names, KMS aliases or log groups.
################################################################################

variable "region" {
  description = "AWS region where the EKS cluster is provisioned."
  type        = string
  default     = "us-east-1"
}

variable "product" {
  description = "Product owning this cluster. Keep \"lerian\" for shared base infrastructure; the cluster is named {product}-{environment}-eks."
  type        = string
  default     = "lerian"
}

variable "environment" {
  description = "Deployment environment. One of dev, stg or prd."
  type        = string

  validation {
    condition     = contains(["dev", "stg", "prd"], var.environment)
    error_message = "The environment must be one of: dev, stg, prd."
  }
}

variable "extra_tags" {
  description = "Additional tags merged on top of the standard Lerian tag set produced by the naming module."
  type        = map(string)
  default     = {}
}

################################################################################
# Network lookup
#
# The VPC is not created here. It is resolved by tag:Name from the
# infra-base/vpc stack, whose name follows the very same naming contract.
################################################################################

variable "vpc_name" {
  description = "Name of the VPC hosting the cluster. Leave empty to derive \"lerian-{environment}-vpc\" from the infra-base/vpc stack."
  type        = string
  default     = ""
}

variable "subnet_tag_type" {
  description = "Value of the subnet tag `Type` used to select the subnets where nodes and control plane ENIs are placed. The infra-base/vpc stack tags private subnets with Type=private."
  type        = string
  default     = "private"
}

################################################################################
# Control plane
################################################################################

variable "cluster_version" {
  description = "Kubernetes <major>.<minor> version for the EKS control plane."
  type        = string
  default     = "1.36"
}

variable "cluster_endpoint_private_access" {
  description = "Whether the private Kubernetes API server endpoint is enabled. Keep true so in-VPC workloads and CI runners reach the API without traversing the internet."
  type        = bool
  default     = true
}

variable "cluster_endpoint_public_access" {
  description = "Whether the public Kubernetes API server endpoint is enabled. Keep false in prd; when true, always constrain allowed_api_access_cidrs."
  type        = bool
  default     = false
}

variable "allowed_api_access_cidrs" {
  description = "CIDR blocks allowed to reach the public API server endpoint. Only meaningful when cluster_endpoint_public_access is true; an empty list makes AWS default to 0.0.0.0/0. Entries must be routable public IPv4 - the stack rejects malformed/IPv6 entries, the RFC 5737 documentation ranges and the other reserved blocks AWS refuses in publicAccessCidrs, and private/CGNAT ranges that would match nothing, all with plan-time preconditions rather than an AWS error mid-apply. Find the right value with: curl -s https://checkip.amazonaws.com"
  type        = list(string)
  default     = []
}

variable "enable_cluster_creator_admin_permissions" {
  description = "Whether the IAM identity running Terraform is added as a cluster administrator access entry."
  type        = bool
  default     = true
}

variable "enabled_log_types" {
  description = "Control plane log types shipped to CloudWatch Logs."
  type        = list(string)
  default     = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  validation {
    condition = length(setsubtract(var.enabled_log_types, [
      "api", "audit", "authenticator", "controllerManager", "scheduler"
    ])) == 0
    error_message = "Valid log types are: api, audit, authenticator, controllerManager, scheduler."
  }
}

variable "cloudwatch_log_group_retention_in_days" {
  description = "Retention of the control plane log group /aws/eks/{cluster-name}/cluster. Lower it in dev to cut cost."
  type        = number
  default     = 90
}

################################################################################
# Managed node groups
#
# Configurable map so a client can run a general pool plus dedicated pools for
# heavy workloads (taints + labels). The default reproduces the single "default"
# node group this stack historically created.
################################################################################

variable "node_groups" {
  description = <<-EOT
    Map of EKS managed node groups. The map key becomes the node group suffix:
    key "default" yields node group and node IAM role named
    "{product}-{environment}-eks-default".

    Instance sizing guidance based on TPS requirements:
      ARM (21-37% better price/performance, requires an ARM ami_type):
        - Low TPS (<500): c7g.large
        - Medium TPS (500-1500): c7g.xlarge
        - High TPS (>1500): c7g.2xlarge
      x86_64:
        - Low TPS (<500): c6i.large
        - Medium TPS (500-1500): c6i.xlarge
        - High TPS (>1500): c6i.2xlarge
      Non-production only: t3.*/t4g.* burstable types.

    disk_size = null keeps the AMI default root volume. Any other value creates a
    gp3, encrypted root volume of that size.
  EOT

  type = map(object({
    instance_types = optional(list(string), ["c7g.large"])
    ami_type       = optional(string, "AL2023_ARM_64_STANDARD")
    capacity_type  = optional(string, "ON_DEMAND")
    min_size       = optional(number, 5)
    max_size       = optional(number, 15)
    desired_size   = optional(number, 5)
    disk_size      = optional(number)
    labels         = optional(map(string), {})
    taints = optional(map(object({
      key    = string
      value  = optional(string)
      effect = string
    })), {})
    attach_cluster_primary_security_group = optional(bool, true)
    create_security_group                 = optional(bool, false)
    tags                                  = optional(map(string), {})
  }))

  default = {
    default = {}
  }

  validation {
    condition     = length(var.node_groups) > 0
    error_message = "At least one node group must be defined."
  }

  validation {
    condition = alltrue([
      for k, v in var.node_groups : can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", k))
    ])
    error_message = "Node group keys must be lowercase alphanumeric with single hyphens, and must not start or end with a hyphen."
  }

  validation {
    condition = alltrue([
      for k, v in var.node_groups : contains(["ON_DEMAND", "SPOT"], v.capacity_type)
    ])
    error_message = "capacity_type must be either ON_DEMAND or SPOT."
  }

  validation {
    condition = alltrue([
      for k, v in var.node_groups : contains([
        // AL2_* is kept accepted for clusters still on 1.32 or older. Amazon
        // Linux 2 has no EKS-optimized AMI from 1.33 onward, and asking for one
        // fails deep inside the module with an SSM ParameterNotFound that names
        // a path, not the cause:
        //   reading SSM Parameter (/aws/service/eks/optimized-ami/1.36/
        //   amazon-linux-2/recommended/release_version): couldn't find resource
        // The precondition below turns that into a sentence.
        "AL2_x86_64", "AL2_x86_64_GPU", "AL2_ARM_64",
        "AL2023_x86_64_STANDARD", "AL2023_ARM_64_STANDARD",
        "AL2023_x86_64_NVIDIA", "AL2023_x86_64_NEURON",
        "BOTTLEROCKET_x86_64", "BOTTLEROCKET_ARM_64",
      ], v.ami_type)
    ])
    error_message = "ami_type must be one of: AL2_x86_64, AL2_x86_64_GPU, AL2_ARM_64, AL2023_x86_64_STANDARD, AL2023_ARM_64_STANDARD, AL2023_x86_64_NVIDIA, AL2023_x86_64_NEURON, BOTTLEROCKET_x86_64, BOTTLEROCKET_ARM_64."
  }

  validation {
    condition = alltrue([
      for k, v in var.node_groups :
      v.min_size <= v.desired_size && v.desired_size <= v.max_size
    ])
    error_message = "Each node group must satisfy min_size <= desired_size <= max_size."
  }
}

################################################################################
# IRSA roles
#
# Roles only. The controllers themselves are installed with Helm/GitOps after
# the cluster exists (see README).
################################################################################

variable "create_autoscaler_role" {
  description = "Whether to create the IRSA role for the Kubernetes Cluster Autoscaler (service account kube-system:cluster-autoscaler). Also adds the ASG auto-discovery tags to every node group."
  type        = bool
  default     = true
}

variable "create_load_balancer_controller_role" {
  description = "Whether to create the IRSA role for the AWS Load Balancer Controller (service account kube-system:aws-load-balancer-controller)."
  type        = bool
  default     = true
}

variable "create_external_dns_role" {
  description = "Whether to create the IRSA role for ExternalDNS (service account kube-system:external-dns), used to publish records into the private Route53 zone."
  type        = bool
  default     = false
}

variable "external_dns_hosted_zone_arns" {
  description = "Route53 hosted zone ARNs ExternalDNS may write to. PUBLIC ingress DNS only — this repository provisions no private zone. Narrow the default wildcard to the specific hosted zone the cluster is allowed to write to before production."
  type        = list(string)
  default     = ["arn:aws:route53:::hostedzone/*"]
}

variable "create_cert_manager_role" {
  description = "Whether to create the IRSA role for cert-manager (service account cert-manager:cert-manager), used for Route53 DNS-01 challenges."
  type        = bool
  default     = false
}

variable "cert_manager_hosted_zone_arns" {
  description = "Route53 hosted zone ARNs cert-manager may write DNS-01 challenge records to."
  type        = list(string)
  default     = ["arn:aws:route53:::hostedzone/*"]
}
