################################################################################
# Gating
################################################################################

variable "enabled" {
  description = "Perform the lookups. Set it to `var.mode == \"dedicated\"` in a product root stack: in shared mode the datastore modules resolve everything from DNS and Secrets Manager, so this module must resolve NOTHING — the VPC is not even required to exist for the plan to succeed. Every data source in this module is gated on it, and every output degrades to null or an empty list when it is false."
  type        = bool
  default     = true
}

variable "environment" {
  description = "Deployment environment. One of dev, stg or prd. It is the only input the three derived cross-stack names need in the normal case."
  type        = string

  validation {
    condition     = contains(["dev", "stg", "prd"], var.environment)
    error_message = "The environment must be one of: dev, stg, prd."
  }
}

################################################################################
# Cross-stack identifiers
#
# Both are OWNED BY infra-base and therefore carry the "lerian" product label,
# not the product label of the caller. Deriving them from the naming module
# seeded with product = "midaz" would produce midaz-{env}-vpc and midaz-{env}-eks,
# which do not exist — which is why this module derives them from literals and
# why the product roots that call it do not use naming either.
################################################################################

variable "vpc_name" {
  description = "tag:Name of the VPC the product's datastores live in. Leave empty (the default) to DERIVE \"lerian-{environment}-vpc\", which is what infra-base/vpc creates and exports as its vpc_name output."
  type        = string
  default     = ""
}

variable "eks_cluster_name" {
  description = "Name of the EKS cluster whose node security group is resolved. Leave empty (the default) to DERIVE \"lerian-{environment}-eks\" — the cluster belongs to infra-base and carries the \"lerian\" product label, NOT the product's. The lookup matches the node security group by tag:Name = \"{cluster}-node\", which is what terraform-aws-modules/eks sets."
  type        = string
  default     = ""
}

################################################################################
# Ingress
#
# Two sources, for the reason documented in products/shared-resources: the
# product workloads run on the EKS nodes, and every datastore has to be
# reachable from them on the first apply, before anyone has wired a security
# group by hand.
#
#   1. allow_private_subnet_cidr_ingress (default true) — the CIDRs of the
#      subnet_tag_type subnets, resolved from the VPC. Works from the first
#      apply and needs nothing but infra-base/vpc.
#
#   2. the EKS node security group, resolved by tag when the cluster exists.
#      Empty (and harmless) before that: the lookup uses the PLURAL data source.
#
# Plus allowed_security_group_ids / allowed_cidr_blocks for anything else.
################################################################################

variable "subnet_tag_type" {
  description = "Value of tag:Type used to select the subnets whose CIDRs become ingress. \"private\" is where the EKS nodes and the interface VPC endpoints live, which is why it is the default and why it is deliberately NOT the whole VPC CIDR. CAUTION: this is NOT the subnet_tag_type a datastore module takes — that one (\"database\") selects the subnets the instance is PLACED in. A product root stack passes its own var.subnet_tag_type to the datastore module and leaves this one at its default; passing \"database\" here would authorise the wrong CIDRs."
  type        = string
  default     = "private"
}

variable "allow_private_subnet_cidr_ingress" {
  description = "Allow the CIDR blocks of the subnet_tag_type subnets to reach the datastores. This is the DEFAULT ingress path and the reason a product stack can be applied before infra-base/eks exists. It is strictly tighter than the VPC-CIDR fallback the datastore modules ship, which additionally covers the public subnets. Set it to false once the EKS node security group is being resolved, to move to security-group-only ingress."
  type        = bool
  default     = true
}

variable "eks_node_security_group_lookup_enabled" {
  description = "Resolve the EKS node security group by tag and add it to ingress_security_group_ids. Safe to leave true before infra-base/eks exists: the lookup uses data \"aws_security_groups\" (PLURAL), which returns an empty list rather than failing the plan, so the calling stack stays appliable and starts producing the rule on the first apply after the cluster exists."
  type        = bool
  default     = true
}

variable "allowed_security_group_ids" {
  description = "Extra security group IDs to merge into ingress_security_group_ids, on top of the EKS node security group."
  type        = list(string)
  default     = []
}

variable "allowed_cidr_blocks" {
  description = "Extra CIDR blocks to merge into ingress_cidr_blocks, on top of the private subnet CIDRs."
  type        = list(string)
  default     = []
}
