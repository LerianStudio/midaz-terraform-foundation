################################################################################
# Naming and mode
################################################################################

variable "product" {
  description = "Lerian product this datastore belongs to (e.g. midaz, reporter). Use \"shared\" for the tier owned by products/shared-resources/valkey — NOT \"lerian\", which labels the foundation (lerian-{env}-vpc, lerian-{env}-eks)."
  type        = string
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
  description = "\"dedicated\" provisions a Valkey replication group for this product. \"shared\" provisions nothing and only resolves the group created by infra-base."
  type        = string
  default     = "dedicated"

  validation {
    condition     = contains(["dedicated", "shared"], var.mode)
    error_message = "The mode must be one of: dedicated, shared."
  }
}

variable "extra_tags" {
  description = "Additional tags merged on top of the standard Lerian tag set."
  type        = map(string)
  default     = {}
}

################################################################################
# Network lookups
################################################################################

variable "vpc_name" {
  description = "tag:Name of the VPC to deploy into. Defaults to \"lerian-{environment}-vpc\" when empty."
  type        = string
  default     = ""
}

variable "subnet_tag_type" {
  description = "Value of the tag:Type used to select the subnets for the cache subnet group."
  type        = string
  default     = "database"
}

################################################################################
# Ingress
#
# The three variables below implement ONE rule, worded identically in all five
# Lerian datastore modules. Do not diverge them.
################################################################################

variable "allowed_security_group_ids" {
  description = "Security group IDs allowed to reach the datastore port. Any entry here or in allowed_cidr_blocks disables the VPC CIDR fallback: only what is listed is allowed, and nothing is added on top. When both lists are empty the fallback in allow_vpc_cidr_ingress decides."
  type        = list(string)
  default     = []
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed to reach the datastore port. Any entry here or in allowed_security_group_ids disables the VPC CIDR fallback: only what is listed is allowed, and nothing is added on top. When both lists are empty the fallback in allow_vpc_cidr_ingress decides."
  type        = list(string)
  default     = []
}

variable "allow_vpc_cidr_ingress" {
  description = "FALLBACK ONLY. Allow the whole VPC CIDR to reach the datastore port when allowed_cidr_blocks and allowed_security_group_ids are BOTH empty - the pre-refactor behaviour, kept so a migrated stack does not silently lose connectivity. It is never applied on top of a non-empty allow list. Set false to make empty allow lists mean no ingress at all; a check block then warns that the datastore is unreachable."
  type        = bool
  default     = true
}

################################################################################
# DNS
################################################################################

################################################################################
# Shared mode
################################################################################

variable "shared_identifier" {
  description = "Override for the ElastiCache replication group id resolved in shared mode. Defaults to \"shared-{environment}-valkey\", which is what products/shared-resources/valkey creates with product = \"shared\". Only needed when the shared tier was named outside this Terraform."
  type        = string
  default     = ""
}

variable "shared_secret_name" {
  description = "Override for the Secrets Manager secret name resolved in shared mode. Defaults to \"shared-{environment}-valkey/auth-token\"."
  type        = string
  default     = ""
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
  description = "Valkey parameter group family."
  type        = string
  default     = "valkey7"
}

variable "parameters" {
  description = "A list of Valkey parameters to apply."
  type = list(object({
    name  = string
    value = string
  }))
  default = [
    {
      name  = "latency-tracking"
      value = "yes"
    }
  ]
}

variable "port" {
  description = "Port the cache nodes accept connections on."
  type        = number
  default     = 6379
}

################################################################################
# Sizing and availability
################################################################################

variable "node_type" {
  description = "Valkey node type."
  type        = string
  default     = "cache.m7g.large"
}

variable "num_cache_clusters" {
  description = "Number of cache clusters (primary and replicas) in the replication group. Must be at least 2 when multi_az_enabled is true. Null keeps the upstream default of 1."
  type        = number
  default     = null
}

variable "automatic_failover_enabled" {
  description = "Whether a read replica is automatically promoted when the primary fails. Required when multi_az_enabled is true. Null keeps the upstream default."
  type        = bool
  default     = null
}

variable "multi_az_enabled" {
  description = "Whether Multi-AZ support is enabled for the replication group."
  type        = bool
  default     = false
}

variable "snapshot_retention_limit" {
  description = "Number of days ElastiCache retains automatic snapshots. Null keeps the upstream default (no automatic snapshots)."
  type        = number
  default     = null
}

################################################################################
# Security
################################################################################

variable "at_rest_encryption_enabled" {
  description = "Whether to enable encryption at rest."
  type        = bool
  default     = true
}

variable "transit_encryption_enabled" {
  description = "Enable transit encryption for the Valkey cluster."
  type        = bool
  default     = true
}

variable "transit_encryption_mode" {
  description = "Transit encryption mode. Valid values are preferred and required."
  type        = string
  default     = "preferred"

  validation {
    condition     = contains(["preferred", "required"], var.transit_encryption_mode)
    error_message = "transit_encryption_mode must be either 'preferred' or 'required'."
  }
}

variable "auth_token_enabled" {
  description = "Whether to apply the generated auth token to the replication group. The token is always generated and stored in Secrets Manager; this only controls whether ElastiCache enforces it. Requires transit_encryption_enabled = true. Defaults to false, which matches the pre-refactor stack (Midaz does not yet ship TLS client configuration)."
  type        = bool
  default     = false
}

################################################################################
# Maintenance
################################################################################

variable "maintenance_window" {
  description = "Weekly maintenance window, format ddd:hh24:mi-ddd:hh24:mi (UTC)."
  type        = string
  default     = "mon:00:00-mon:03:00"
}

variable "apply_immediately" {
  description = "Whether modifications are applied immediately, or during the next maintenance window."
  type        = bool
  default     = false
}
