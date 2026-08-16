################################################################################
# Stack identity
################################################################################

variable "region" {
  description = "AWS region the cluster is created in. Must be the region the infra-base VPC lives in."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", var.region))
    error_message = "The region must be a valid AWS region identifier, e.g. us-east-1 or sa-east-1."
  }
}

variable "product" {
  description = "Product this cluster belongs to. Pinned to \"reporter\" by validation: the derived name (reporter-{env}-docdb) and the derived secret path (reporter-{env}-docdb/password) ARE the cross-stack discovery contract. A different value here silently produces resources the reporter Helm release cannot find. A second product gets its own directory under examples/aws/products, not a different value here."
  type        = string
  default     = "reporter"

  validation {
    condition     = var.product == "reporter"
    error_message = "The product must be \"reporter\". This root stack is the reporter cluster; every name and secret path it produces is derived from it. To provision this service for another product, copy this directory to examples/aws/products/<product>/documentdb instead."
  }
}

variable "environment" {
  description = "Deployment environment. One of dev, stg or prd."
  type        = string

  validation {
    condition     = contains(["dev", "stg", "prd"], var.environment)
    error_message = "The environment must be one of: dev, stg, prd."
  }
}

variable "mode" {
  description = "\"dedicated\" creates a cluster owned by reporter (reporter-{env}-docdb). \"shared\" creates nothing and resolves the one owned by products/shared-resources/documentdb, looked up by name: shared-{env}-docdb plus the secret shared-{env}-docdb/password. In shared mode this stack resolves no VPC, no subnets and no EKS security group, and plans to zero resources."
  type        = string
  default     = "dedicated"

  validation {
    condition     = contains(["dedicated", "shared"], var.mode)
    error_message = "The mode must be one of: dedicated, shared."
  }
}

variable "extra_tags" {
  description = "Additional tags merged on top of the standard Lerian tag set (Product, Environment, ManagedBy, Repository)."
  type        = map(string)
  default     = {}
}

################################################################################
# Network context
#
# Both names are OWNED BY the infra-base FOUNDATION and therefore carry the
# "lerian" product label — not "reporter", and not "shared" either (that one
# labels the shared DATASTORE tier in products/shared-resources). Deriving them
# from module.naming here would produce reporter-{env}-vpc / reporter-{env}-eks,
# which do not exist — which is why this root stack does not call the naming
# module at all.
################################################################################

variable "vpc_name" {
  description = "tag:Name of the VPC the cluster is placed in. Leave empty (the default) to DERIVE \"lerian-{environment}-vpc\", which is what infra-base/vpc creates and exports as its vpc_name output."
  type        = string
  default     = ""
}

variable "subnet_tag_type" {
  description = "Value of the tag:Type used to select the subnets the cluster is placed in. infra-base/vpc tags its three database subnets with Type=database, which is the lookup contract."
  type        = string
  default     = "database"
}

################################################################################
# Ingress
#
# Same two-source model as products/shared-resources, for the same reason: the
# reporter workloads run on the EKS nodes, and the cluster has to be
# reachable from them on the first apply, before anyone has wired a security
# group by hand.
#
#   1. allow_private_subnet_cidr_ingress (default true) — the CIDRs of the
#      Type=private subnets, resolved from the VPC. Works from the first apply
#      and needs nothing but infra-base/vpc.
#
#   2. the EKS node security group, resolved by tag when the cluster exists.
#      Empty (and harmless) before that: the lookup uses the PLURAL data source.
#
# Plus allowed_security_group_ids / allowed_cidr_blocks for anything else.
################################################################################

variable "allowed_security_group_ids" {
  description = "Extra security group IDs allowed to reach the cluster on its port. Merged with the EKS node security group when eks_node_security_group_lookup_enabled is true."
  type        = list(string)
  default     = []
}

variable "allowed_cidr_blocks" {
  description = "Extra CIDR blocks allowed to reach the cluster on its port. Merged with the private subnet CIDRs when allow_private_subnet_cidr_ingress is true."
  type        = list(string)
  default     = []
}

variable "allow_private_subnet_cidr_ingress" {
  description = "Allow the CIDR blocks of the Type=private subnets to reach the cluster. This is the DEFAULT ingress path and the reason this stack can be applied before infra-base/eks exists. It is strictly tighter than the VPC-CIDR fallback the module ships, which additionally covers the public subnets. Set it to false once the EKS node security group is being resolved, to move to security-group-only ingress."
  type        = bool
  default     = true
}

variable "eks_node_security_group_lookup_enabled" {
  description = "Resolve the EKS node security group by tag and allow it on the cluster. Safe to leave true before infra-base/eks exists: the lookup uses data \"aws_security_groups\" (PLURAL), which returns an empty list rather than failing the plan, so this stack stays appliable and starts producing the rule on the first apply after the cluster exists."
  type        = bool
  default     = true
}

variable "eks_cluster_name" {
  description = "Name of the EKS cluster whose node security group is resolved. Leave empty (the default) to DERIVE \"lerian-{environment}-eks\" — the cluster belongs to infra-base and carries the \"lerian\" product label, NOT \"reporter\". The lookup matches the node security group by tag:Name = \"{cluster}-node\", which is what terraform-aws-modules/eks sets."
  type        = string
  default     = ""
}

variable "allow_vpc_cidr_ingress" {
  description = "Passed straight to the module as its allow_vpc_cidr_ingress input. FALLBACK ONLY: the module applies it exclusively when both allowed_cidr_blocks and allowed_security_group_ids resolve empty; any entry in either list wins outright and the VPC CIDR is never added on top. Kept false here because this stack computes its allow lists explicitly and would rather trip the module's check \"ingress_is_reachable\" than quietly widen to a CIDR that includes the public subnets."
  type        = bool
  default     = false
}

################################################################################
# Engine and sizing
################################################################################

variable "master_username" {
  description = "Master username of the cluster. Feeds MONGO_USER in the reporter-helm chart. Deliberately NOT marked sensitive at this level: the module marks its own copy sensitive, and reading it back through that output would redact the whole helm_values map and defeat the handoff. In mode = \"shared\" this is therefore the value the CALLER declares, not a read of the shared cluster — keep it equal to the shared tier's master username (both default to \"docdbadmin\")."
  type        = string
  default     = "docdbadmin"
}

variable "port" {
  description = "Port the cluster listens on."
  type        = number
  default     = 27017
}

variable "instance_class" {
  description = "Instance class for the cluster instances. db.t3.medium is the SMALLEST class DocumentDB offers — the RDS micro/small sizes do not exist for this service and the module rejects them with a plan-time precondition rather than five minutes into the apply."
  type        = string
  default     = "db.t3.medium"
}

variable "instances_count" {
  description = "Number of instances in the cluster. 1 in dev, 2 or more in stg/prd (an instance per AZ is what makes the cluster survive an AZ loss)."
  type        = number
  default     = 1

  validation {
    condition     = var.instances_count >= 1
    error_message = "The instances_count must be at least 1."
  }
}

variable "engine_version" {
  description = "DocumentDB engine version. Null takes the AWS default for parameter_group_family."
  type        = string
  default     = null
}

variable "parameter_group_family" {
  description = "DocumentDB cluster parameter group family. Must match engine_version."
  type        = string
  default     = "docdb5.0"
}

variable "documentdb_tls" {
  description = "Value of the DocumentDB \"tls\" cluster parameter: enabled or disabled. Safe to enable as far as the HOST is concerned: helm_values always carries the raw *.docdb.amazonaws.com writer endpoint, which is exactly what the DocumentDB certificate covers. Pair it with MONGO_TLS_CA_CERT in the chart (the global RDS CA bundle, which Terraform does not distribute)."
  type        = string
  default     = "disabled"

  validation {
    condition     = contains(["enabled", "disabled"], var.documentdb_tls)
    error_message = "The documentdb_tls must be either 'enabled' or 'disabled'."
  }
}

################################################################################
# Maintenance and backup
################################################################################

variable "backup_retention_period" {
  description = "Automated backup retention in days."
  type        = number
  default     = 7
}

variable "preferred_backup_window" {
  description = "Daily time range during which automated backups are created, UTC."
  type        = string
  default     = "07:00-09:00"
}

variable "enabled_cloudwatch_logs_exports" {
  description = "DocumentDB log types exported to CloudWatch Logs. Empty in dev keeps the bill down; audit is what a regulator asks for in prd."
  type        = list(string)
  default     = []
}

variable "skip_final_snapshot" {
  description = "Skip the final snapshot when the cluster is destroyed. true in dev, false in prd."
  type        = bool
  default     = true
}

variable "deletion_protection" {
  description = "Protect the cluster from deletion. false in dev, true in prd."
  type        = bool
  default     = false
}

variable "apply_immediately" {
  description = "Apply cluster modifications immediately instead of waiting for the maintenance window."
  type        = bool
  default     = false
}
