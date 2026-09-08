################################################################################
# Stack identity
#
# There is no `mode` variable in this root, deliberately. The module call is
# pinned to mode = "dedicated" because this stack is the OWNER of the shared
# instance — see the header of main.tf. A shared-mode shared tier would resolve
# a resource nobody created and apply cleanly to an empty state.
#
# There is no `postgres_enabled` toggle either. Enabling this datastore is
# applying this directory.
################################################################################

variable "region" {
  description = "AWS region the shared instance is created in. Must be the region the infra-base VPC lives in."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", var.region))
    error_message = "The region must be a valid AWS region identifier, e.g. us-east-1 or sa-east-1."
  }
}

variable "product" {
  description = "Product label this datastore carries. Keep the default \"shared\": that is what makes the derived name (shared-{env}-postgres) and the derived secret path (shared-{env}-postgres/password) match exactly what postgres-rds looks up when a product sets mode = \"shared\". Changing it makes every shared consumer unresolvable. NOTE the deliberate split: the FOUNDATION stacks keep the \"lerian\" label (lerian-{env}-vpc, lerian-{env}-eks) because they are unconditionally shared and have no dedicated counterpart; this DATASTORE tier carries \"shared\" because here the dedicated/shared choice exists and the label is what distinguishes shared-dev-postgres from midaz-dev-postgres. Do not unify them."
  type        = string
  default     = "shared"

  validation {
    condition     = var.product == "shared"
    error_message = "The product must be \"shared\". The shared mode of postgres-rds derives the name it looks up as \"shared-{environment}-postgres\" and the secret as \"shared-{environment}-postgres/password\". A different product here produces an instance no shared consumer can find. If you genuinely want a second PostgreSQL instance, that is a product root stack with mode = \"dedicated\", not this one."
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
# Deriving them from a naming module seeded with product = "shared" would
# produce shared-{env}-vpc / shared-{env}-eks, which do not exist — which is why
# this root stack does not call the naming module at all.
################################################################################

variable "vpc_name" {
  description = "tag:Name of the VPC the instance is placed in. Leave empty (the default) to DERIVE \"lerian-{environment}-vpc\", which is what infra-base/vpc creates and exports as its vpc_name output."
  type        = string
  default     = ""
}

variable "subnet_tag_type" {
  description = "Value of the tag:Type used to select the subnets for the DB subnet group. infra-base/vpc tags its three database subnets with Type=database, which is the lookup contract."
  type        = string
  default     = "database"
}

################################################################################
# Ingress — the part the shared model lives or dies on
#
# A product running with mode = "shared" gets security_group_id = null from its
# module: it creates no security group and therefore cannot authorise itself.
# Opening the shared instance is exclusively this stack's job.
#
# Two independent sources:
#
#   1. allow_private_subnet_cidr_ingress (default true) — the CIDRs of the
#      Type=private subnets, resolved from the VPC. Works from the first apply,
#      needs nothing but infra-base/vpc.
#
#   2. the EKS node security group, resolved by tag when the cluster exists.
#      Empty (and harmless) before that: the lookup uses data "aws_security_groups"
#      (PLURAL), which returns an empty list instead of failing the plan.
#
# Plus allowed_security_group_ids / allowed_cidr_blocks for anything else.
################################################################################

variable "allowed_security_group_ids" {
  description = "Extra security group IDs allowed to reach the instance on its port. Merged with the EKS node security group when eks_node_security_group_lookup_enabled is true."
  type        = list(string)
  default     = []
}

variable "allowed_cidr_blocks" {
  description = "Extra CIDR blocks allowed to reach the instance on its port. Merged with the private subnet CIDRs when allow_private_subnet_cidr_ingress is true."
  type        = list(string)
  default     = []
}

variable "allow_private_subnet_cidr_ingress" {
  description = <<-EOT
    Allow the CIDR blocks of the Type=private subnets to reach the instance. This
    is the DEFAULT ingress path and the reason this stack can be applied before
    infra-base/eks exists.

    Scope: the private subnets hold the EKS nodes and the interface VPC
    endpoints. It is strictly tighter than the VPC-CIDR fallback the module
    ships, which additionally covers the public subnets. Because any non-empty
    allow list disables that fallback outright, setting this true is what keeps
    the shared tier off the public subnets.

    Set it to false once infra-base/eks exists and the node security group is
    being resolved, to move to security-group-only ingress.
  EOT
  type        = bool
  default     = true
}

variable "eks_node_security_group_lookup_enabled" {
  description = "Resolve the EKS node security group by tag and allow it on the instance. Safe to leave true before infra-base/eks exists: the lookup uses data \"aws_security_groups\" (PLURAL), which returns an empty list rather than failing the plan, so this stack stays appliable and starts producing the rule on the first apply after the cluster exists."
  type        = bool
  default     = true
}

variable "eks_cluster_name" {
  description = "Name of the EKS cluster whose node security group is resolved. Leave empty (the default) to DERIVE \"lerian-{environment}-eks\" — the cluster belongs to infra-base and carries the \"lerian\" product label, NOT \"shared\". The lookup matches the node security group by tag:Name = \"{cluster}-node\", which is what terraform-aws-modules/eks sets."
  type        = string
  default     = ""
}

variable "allow_vpc_cidr_ingress" {
  description = "Passed straight to the module as its allow_vpc_cidr_ingress input. FALLBACK ONLY: the module applies it exclusively when both allowed_cidr_blocks and allowed_security_group_ids resolve empty; any entry in either list wins outright and the VPC CIDR is never added on top. Kept false here because this stack computes its allow lists explicitly and would rather trip the module's check \"ingress_is_reachable\" than quietly widen to a CIDR that includes the public subnets."
  type        = bool
  default     = false
}

################################################################################
# Engine
################################################################################

variable "engine_version" {
  description = "PostgreSQL engine version. Keep it MAJOR-only (\"16\"): RDS then picks the latest available minor and the provider treats the config as a prefix, so there is no perpetual diff. Pinning a full minor is a maintenance trap — AWS retired 16.3 and every apply that pinned it started failing with \"Cannot find version 16.3 for postgres\"."
  type        = string
  default     = "16"
}

variable "family" {
  description = "PostgreSQL parameter group family, e.g. postgres16. Must agree with engine_version."
  type        = string
  default     = "postgres16"

  validation {
    condition     = can(regex("^postgres(1[5-9]|[2-9][0-9])$", var.family))
    error_message = "family must be postgres15 or newer. AWS ships rds.force_ssl = 0 on postgres14 and older and 1 from postgres15 on, so an older family creates a server that accepts plaintext connections unless parameters sets rds.force_ssl explicitly."
  }


  validation {
    condition = (
      var.family == "postgres${var.major_engine_version}" &&
      (var.engine_version == var.major_engine_version ||
      startswith(var.engine_version, "${var.major_engine_version}."))
    )
    error_message = "family, major_engine_version and engine_version have to name the same PostgreSQL major. Both descriptions said \"must agree with engine_version\" and nothing checked it, so family = \"postgres15\" with engine_version = \"17\" planned cleanly and RDS refused the combination at apply."
  }

}

variable "major_engine_version" {
  description = "PostgreSQL major engine version, e.g. 16. Must agree with engine_version."
  type        = string
  default     = "16"
}

variable "database_name" {
  description = "Name of the INITIAL database created on the shared instance. Not a resource name, which is why it stays \"lerian\" rather than \"shared\". Products consuming this instance with mode = \"shared\" are expected to use their own schema or their own logical database, created outside Terraform — RDS creates exactly one database at provisioning time."
  type        = string
  default     = "lerian"
}

variable "username" {
  description = "Master username of the shared instance."
  type        = string
  default     = "postgres"
}

################################################################################
# Sizing and storage
################################################################################

variable "instance_class" {
  description = "Instance class. db.t4g.micro is the cheapest class RDS offers for PostgreSQL and is the intended dev value; it does NOT support Performance Insights."
  type        = string
  default     = "db.t4g.micro"
}

variable "allocated_storage" {
  description = "Allocated storage in GB."
  type        = number
  default     = 20
}

variable "max_allocated_storage" {
  description = "Storage autoscaling ceiling in GB."
  type        = number
  default     = 100
}

variable "multi_az" {
  description = "Deploy the instance across two availability zones. Roughly doubles the instance cost."
  type        = bool
  default     = false
}

################################################################################
# Read replica
################################################################################

variable "create_read_replica" {
  description = "Create a read replica, shared-{env}-postgres-replica, published as the replica_endpoint output — the host a reporting or read-heavy consumer should point at instead of the writer."
  type        = bool
  default     = false
}

variable "read_replica_instance_class" {
  description = "Instance class of the read replica. The module passes it straight through, so set it whenever create_read_replica is true."
  type        = string
  default     = null
}

variable "read_replica_multi_az" {
  description = "Deploy the read replica across two availability zones."
  type        = bool
  default     = false
}

################################################################################
# Maintenance and backup
################################################################################

variable "backup_retention_period" {
  description = "Automated backup retention in days."
  type        = number
  default     = 7
}

variable "skip_final_snapshot" {
  description = "Skip the final snapshot when the instance is destroyed. true in dev, false in stg/prd — a shared instance holds more than one product's data, so the snapshot is worth more here than on a product root."
  type        = bool
  default     = false
}

variable "deletion_protection" {
  description = "Protect the instance from deletion. false in dev, true in stg/prd. Destroying the shared tier takes every consuming product down with it."
  type        = bool
  default     = true
}

################################################################################
# Monitoring
################################################################################

variable "monitoring_interval" {
  description = "Enhanced Monitoring interval in seconds. 0 disables it, which also makes the monitoring IAM role unnecessary."
  type        = number
  default     = 0

  validation {
    condition     = contains([0, 1, 5, 10, 15, 30, 60], var.monitoring_interval)
    error_message = "The monitoring_interval must be one of: 0, 1, 5, 10, 15, 30, 60."
  }
}

variable "create_monitoring_role" {
  description = "Create the RDS Enhanced Monitoring IAM role. Keep it aligned with monitoring_interval: a role with no monitoring is dead weight, monitoring with no role fails the apply."
  type        = bool
  default     = false
}

variable "performance_insights_enabled" {
  description = "Enable Performance Insights. AWS does NOT offer it on db.t2/t3/t4g micro and small, and the module rejects that combination with a plan-time precondition — so this MUST be false on the db.t4g.micro dev sizing."
  type        = bool
  default     = false
}

variable "performance_insights_retention_period" {
  description = "Days of Performance Insights data retained. Valid values are 7, 731, or a multiple of 31."
  type        = number
  default     = 7
}

variable "enabled_cloudwatch_logs_exports" {
  description = "PostgreSQL log types exported to CloudWatch Logs. An empty list also skips the log groups."
  type        = list(string)
  default     = ["postgresql", "upgrade"]
}

variable "parameters" {
  description = "DB parameters applied to the parameter group, as a list of {name, value} (and optionally apply_method for a static parameter that needs a reboot). THIS IS WHERE TLS IS ENFORCED: rds.force_ssl = \"1\" makes the server REFUSE any non-TLS connection, and until this variable existed no root wrapper could state it at all — the module ships an empty parameter list and nothing populated it. Set it EXPLICITLY rather than inheriting: the RDS default for force_ssl varies by engine major (0 on the older postgres families, 1 from postgres15 on), so a database with no entry here has a posture that depends on which version it happened to be created at, and silently loosens on a downgrade or a restore into an older family. Encryption in transit is a client policy decision everywhere else in this repo; on a money path it is not."
  type = list(object({
    name         = string
    value        = string
    apply_method = optional(string)
  }))
  default = []

  validation {
    condition = alltrue([
      for p in var.parameters : contains(["immediate", "pending-reboot"], p.apply_method == null ? "immediate" : p.apply_method)
    ])
    error_message = "Each parameters[*].apply_method must be \"immediate\" or \"pending-reboot\" — the only two the AWS provider accepts. Omit it to take the provider default (\"immediate\"); use \"pending-reboot\" for a static parameter such as rds.force_ssl."
  }

  validation {
    condition = alltrue([
      for p in var.parameters : p.value == "1" if p.name == "rds.force_ssl"
    ])
    error_message = "rds.force_ssl cannot be set to anything but \"1\": the server has to refuse non-TLS connections. Omit the entry to inherit the family default, which is 1 from postgres15 on."
  }

}
