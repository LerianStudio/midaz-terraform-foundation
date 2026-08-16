################################################################################
# Stack identity
#
# There is no `mode` variable in this root, deliberately. The module call is
# pinned to mode = "dedicated" because this stack is the OWNER of the shared
# replication group — see the header of main.tf.
#
# There is no `valkey_enabled` toggle either. Enabling this datastore is
# applying this directory.
################################################################################

variable "region" {
  description = "AWS region the shared replication group is created in. Must be the region the infra-base VPC lives in."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", var.region))
    error_message = "The region must be a valid AWS region identifier, e.g. us-east-1 or sa-east-1."
  }
}

variable "product" {
  description = "Product label this datastore carries. Keep the default \"shared\": that is what makes the derived name (shared-{env}-valkey) and the derived secret path (shared-{env}-valkey/auth-token) match exactly what valkey-elasticache looks up when a product sets mode = \"shared\". Changing it makes every shared consumer unresolvable. The FOUNDATION stacks keep the \"lerian\" label (lerian-{env}-vpc, lerian-{env}-eks) because they have no dedicated counterpart; this DATASTORE tier carries \"shared\" because here the choice exists and the label is what distinguishes shared-dev-valkey from midaz-dev-valkey."
  type        = string
  default     = "shared"

  validation {
    condition     = var.product == "shared"
    error_message = "The product must be \"shared\". The shared mode of valkey-elasticache derives the name it looks up as \"shared-{environment}-valkey\" and the secret as \"shared-{environment}-valkey/auth-token\". A different product here produces a group no shared consumer can find. If you genuinely want a second group, that is a product root stack with mode = \"dedicated\", not this one."
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
  description = "tag:Name of the VPC the replication group is placed in. Leave empty (the default) to DERIVE \"lerian-{environment}-vpc\", which is what infra-base/vpc creates and exports as its vpc_name output."
  type        = string
  default     = ""
}

variable "subnet_tag_type" {
  description = "Value of the tag:Type used to select the subnets for the cache subnet group. infra-base/vpc tags its three database subnets with Type=database, which is the lookup contract."
  type        = string
  default     = "database"
}

################################################################################
# Ingress — the part the shared model lives or dies on
#
# A product running with mode = "shared" gets security_group_id = null from its
# module: it creates no security group and therefore cannot authorise itself.
# Opening the shared group is exclusively this stack's job.
################################################################################

variable "allowed_security_group_ids" {
  description = "Extra security group IDs allowed to reach the replication group on its port. Merged with the EKS node security group when eks_node_security_group_lookup_enabled is true."
  type        = list(string)
  default     = []
}

variable "allowed_cidr_blocks" {
  description = "Extra CIDR blocks allowed to reach the replication group on its port. Merged with the private subnet CIDRs when allow_private_subnet_cidr_ingress is true."
  type        = list(string)
  default     = []
}

variable "allow_private_subnet_cidr_ingress" {
  description = "Allow the CIDR blocks of the Type=private subnets to reach the replication group. This is the DEFAULT ingress path and the reason this stack can be applied before infra-base/eks exists. It is strictly tighter than the VPC-CIDR fallback the module ships, which additionally covers the public subnets. Set it to false once the EKS node security group is being resolved, to move to security-group-only ingress."
  type        = bool
  default     = true
}

variable "eks_node_security_group_lookup_enabled" {
  description = "Resolve the EKS node security group by tag and allow it on the replication group. Safe to leave true before infra-base/eks exists: the lookup uses data \"aws_security_groups\" (PLURAL), which returns an empty list rather than failing the plan."
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
# Engine
################################################################################

variable "engine_version" {
  description = "Valkey engine version."
  type        = string
  default     = "7.2"
}

variable "parameter_group_family" {
  description = "Valkey parameter group family. Must match engine_version."
  type        = string
  default     = "valkey7"
}

variable "port" {
  description = "Port the cache nodes accept connections on. Note the midaz chart concatenates this into REDIS_HOST as \"host:port\" — it has no REDIS_PORT variable."
  type        = number
  default     = 6379
}

################################################################################
# Sizing and availability
################################################################################

variable "node_type" {
  description = "Valkey node type. cache.t4g.micro is the cheapest usable size and is the intended dev value — together with the shared PostgreSQL instance it is the cheapest half of the shared tier, roughly USD 12/month."
  type        = string
  default     = "cache.t4g.micro"
}

variable "num_cache_clusters" {
  description = "Number of cache clusters (primary plus replicas) in the shared replication group. Must be at least 2 when multi_az_enabled is true."
  type        = number
  default     = 1
}

variable "automatic_failover_enabled" {
  description = "Promote a replica automatically when the primary fails. Required when multi_az_enabled is true, and impossible with a single cache cluster."
  type        = bool
  default     = false
}

variable "multi_az_enabled" {
  description = "Spread the replication group across availability zones. Requires num_cache_clusters >= 2 and automatic_failover_enabled = true."
  type        = bool
  default     = false
}

variable "snapshot_retention_limit" {
  description = "Days ElastiCache retains automatic snapshots. 0 means no automatic snapshots."
  type        = number
  default     = 0
}

################################################################################
# Security
################################################################################

variable "transit_encryption_enabled" {
  description = "Enable in-transit encryption on the shared replication group."
  type        = bool
  default     = true
}

variable "transit_encryption_mode" {
  description = "Transit encryption mode: \"preferred\" accepts both TLS and plaintext clients, \"required\" accepts TLS only. Keep it preferred while any consuming chart still connects without TLS — this value is what the helm_values output turns into REDIS_TLS, and on a SHARED group flipping it to \"required\" locks out every consumer that has not been converted."
  type        = string
  default     = "preferred"

  validation {
    condition     = contains(["preferred", "required"], var.transit_encryption_mode)
    error_message = "The transit_encryption_mode must be either 'preferred' or 'required'."
  }
}

variable "auth_token_enabled" {
  description = "Make ElastiCache ENFORCE the auth token. The token is generated and stored in Secrets Manager either way; this only decides whether the server requires it. KNOWN GAP: defaults to false, and stays false in all three tfvars examples, because the Lerian charts do not yet ship a Valkey TLS/AUTH client configuration. On a SHARED group turning it on is all-or-nothing — it locks out every consuming product at once."
  type        = bool
  default     = false
}

################################################################################
# Maintenance
################################################################################

variable "maintenance_window" {
  description = "Weekly maintenance window, ddd:hh24:mi-ddd:hh24:mi in UTC."
  type        = string
  default     = "mon:00:00-mon:03:00"
}

variable "apply_immediately" {
  description = "Apply modifications immediately instead of waiting for the maintenance window. Consider leaving this false on a shared group: an immediate change is an immediate disruption for every consuming product at once."
  type        = bool
  default     = false
}

################################################################################
# Helm handoff extras
################################################################################

variable "redis_db_index" {
  description = "Logical Valkey database index emitted as REDIS_DB. Not an AWS setting — ElastiCache exposes 16 logical databases on every node and Terraform creates none of them. On a SHARED group this is the crudest available isolation between consumers, and coordinating who uses which index is an application concern this stack cannot enforce."
  type        = number
  default     = 0
}
