################################################################################
# Stack identity
#
# There is no `mode` variable in this root, deliberately. The module call is
# pinned to mode = "dedicated" because this stack is the OWNER of the shared
# cluster — see the header of main.tf.
#
# There is no `documentdb_enabled` toggle either. Enabling this datastore is
# applying this directory.
################################################################################

variable "region" {
  description = "AWS region the shared cluster is created in. Must be the region the infra-base VPC lives in."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", var.region))
    error_message = "The region must be a valid AWS region identifier, e.g. us-east-1 or sa-east-1."
  }
}

variable "product" {
  description = "Product label this datastore carries. Keep the default \"shared\": that is what makes the derived name (shared-{env}-docdb) and the derived secret path (shared-{env}-docdb/password) match exactly what mongodb-documentdb looks up when a product sets mode = \"shared\". Changing it makes every shared consumer unresolvable. The FOUNDATION stacks keep the \"lerian\" label (lerian-{env}-vpc, lerian-{env}-eks) because they have no dedicated counterpart; this DATASTORE tier carries \"shared\" because here the choice exists and the label is what distinguishes shared-dev-docdb from midaz-dev-docdb."
  type        = string
  default     = "shared"

  validation {
    condition     = var.product == "shared"
    error_message = "The product must be \"shared\". The shared mode of mongodb-documentdb derives the name it looks up as \"shared-{environment}-docdb\" and the secret as \"shared-{environment}-docdb/password\". A different product here produces a cluster no shared consumer can find. If you genuinely want a second cluster, that is a product root stack with mode = \"dedicated\", not this one."
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

variable "extra_tags" {
  description = "Additional tags merged on top of the standard Lerian tag set (Product, Environment, ManagedBy, Repository)."
  type        = map(string)
  default     = {}
}

################################################################################
# Network context
#
# Both names are OWNED BY the infra-base FOUNDATION and therefore carry the
# "lerian" product label — not "shared", which labels this datastore tier.
################################################################################

variable "vpc_name" {
  description = "tag:Name of the VPC the cluster is placed in. Leave empty (the default) to DERIVE \"lerian-{environment}-vpc\", which is what infra-base/vpc creates and exports as its vpc_name output."
  type        = string
  default     = ""
}

variable "subnet_tag_type" {
  description = "Value of the tag:Type used to select the subnets for the DocumentDB subnet group. infra-base/vpc tags its three database subnets with Type=database, which is the lookup contract."
  type        = string
  default     = "database"
}

################################################################################
# Ingress — the part the shared model lives or dies on
#
# A product running with mode = "shared" gets security_group_id = null from its
# module: it creates no security group and therefore cannot authorise itself.
# Opening the shared cluster is exclusively this stack's job.
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
  description = "Resolve the EKS node security group by tag and allow it on the cluster. Safe to leave true before infra-base/eks exists: the lookup uses data \"aws_security_groups\" (PLURAL), which returns an empty list rather than failing the plan."
  type        = bool
  default     = true
}

variable "eks_cluster_name" {
  description = "Name of the EKS cluster whose node security group is resolved. Leave empty (the default) to DERIVE \"lerian-{environment}-eks\" — the cluster belongs to infra-base and carries the \"lerian\" product label, NOT \"shared\". The lookup matches by tag:Name = \"{cluster}-node\"."
  type        = string
  default     = ""
}

variable "allow_vpc_cidr_ingress" {
  description = "Passed straight to the module as its allow_vpc_cidr_ingress input. FALLBACK ONLY: applied exclusively when both allowed_cidr_blocks and allowed_security_group_ids resolve empty; any entry in either list wins outright and the VPC CIDR is never added on top. Kept false here so an empty allow list trips the module's check \"ingress_is_reachable\" instead of quietly widening to a CIDR that includes the public subnets."
  type        = bool
  default     = false
}

################################################################################
# Engine and sizing
################################################################################

variable "master_username" {
  description = "Master username of the shared cluster. Deliberately NOT marked sensitive at this level: the module marks its own copy sensitive, and reading it back through that output would redact the whole helm_values map and defeat the handoff. A product consuming with mode = \"shared\" declares this value on its own side rather than reading it from the cluster, so keep both at the default \"docdbadmin\"."
  type        = string
  default     = "docdbadmin"
}

variable "port" {
  description = "Port the cluster listens on."
  type        = number
  default     = 27017
}

variable "instance_class" {
  description = "Instance class for the cluster instances. db.t3.medium is the SMALLEST class DocumentDB offers — the RDS micro/small sizes do not exist for this service, and the module rejects them with a plan-time precondition rather than five minutes into the apply. This is why DocumentDB has no cheap corner: roughly USD 60/month for one instance, more than the shared PostgreSQL and Valkey combined."
  type        = string
  default     = "db.t3.medium"
}

variable "instances_count" {
  description = "Number of instances in the shared cluster. 1 in dev, 2 or more in stg/prd — an instance per AZ is what makes the cluster survive an AZ loss, and what makes reader_endpoint point at something other than the writer."
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
  description = <<-EOT
    Value of the DocumentDB "tls" cluster parameter: enabled or disabled.

    KNOWN GAP, shipped "disabled" in all three tfvars examples. The reason is no
    longer the host: consumers receive the raw *.docdb.amazonaws.com writer
    endpoint, which is exactly what the DocumentDB certificate covers, so
    hostname validation passes. (It used to be a real trap — this tier published
    a mongodb.lerian.{zone} CNAME that no certificate covered, and removing the
    private zone is what removed the trap.)

    What is still missing is chart-side: enabling TLS requires the consuming
    charts to mount the global RDS CA bundle into MONGO_*_TLS_CA_CERT, which
    Terraform does not distribute. On a SHARED cluster that switch is
    all-or-nothing — flipping it here forces every consuming product to have the
    CA bundle wired on the same day. Turn it on once they all do.
  EOT
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
  description = "Skip the final snapshot when the cluster is destroyed. true in dev, false in stg/prd — a shared cluster holds more than one product's data."
  type        = bool
  default     = false
}

variable "deletion_protection" {
  description = "Protect the cluster from deletion. false in dev, true in stg/prd. Destroying the shared tier takes every consuming product down with it."
  type        = bool
  default     = true
}

variable "apply_immediately" {
  description = "Apply cluster modifications immediately instead of waiting for the maintenance window. Consider leaving this false on a shared cluster: an immediate change is an immediate restart for every consuming product at once."
  type        = bool
  default     = false
}
