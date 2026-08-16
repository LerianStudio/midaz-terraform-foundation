################################################################################
# Naming and mode
################################################################################

variable "product" {
  description = "Lerian product this datastore belongs to (e.g. midaz, reporter). Use \"shared\" for the tier owned by products/shared-resources/postgres — NOT \"lerian\", which labels the foundation (lerian-{env}-vpc, lerian-{env}-eks)."
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
  description = "\"dedicated\" provisions a PostgreSQL instance for this product. \"shared\" provisions nothing and only resolves the shared instance created by infra-base."
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
  description = "Value of the tag:Type used to select the subnets for the DB subnet group."
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
# Shared mode
################################################################################

variable "shared_identifier" {
  description = "Override for the RDS DB instance identifier resolved in shared mode. Defaults to \"shared-{environment}-postgres\", which is what products/shared-resources/postgres creates with product = \"shared\". Only needed when the shared tier was named outside this Terraform."
  type        = string
  default     = ""
}

variable "shared_secret_name" {
  description = "Override for the Secrets Manager secret name resolved in shared mode. Defaults to \"shared-{environment}-postgres/password\"."
  type        = string
  default     = ""
}

################################################################################
# Engine
################################################################################

variable "engine" {
  description = "Database engine type."
  type        = string
  default     = "postgres"
}

variable "engine_version" {
  description = "PostgreSQL engine version. Prefer a MAJOR-only value such as \"16\": RDS then selects the latest available minor, and the AWS provider treats the config as a prefix of the recorded version so there is no perpetual diff. Pinning a full minor is a maintenance trap — AWS retires minors, and the legacy default \"16.3\" had already stopped existing, so every apply failed with \"Cannot find version 16.3 for postgres\". Pin a full minor only when a specific patch level is contractually required, and then track its deprecation."
  type        = string
  default     = "16"
}

variable "family" {
  description = "Database parameter group family."
  type        = string
  default     = "postgres16"
}

variable "major_engine_version" {
  description = "Database major engine version."
  type        = string
  default     = "16"
}

variable "database_name" {
  description = "Name of the database to create."
  type        = string
}

variable "username" {
  description = "Database master user."
  type        = string
  default     = "postgres"
}

variable "port" {
  description = "Database port."
  type        = number
  default     = 5432
}

variable "parameters" {
  description = "A list of DB parameters to apply."
  type        = list(map(string))
  default     = []
}

################################################################################
# Sizing and storage
################################################################################

variable "instance_class" {
  description = "Instance type for the RDS instance."
  type        = string
  default     = "db.m7g.large"
}

variable "allocated_storage" {
  description = "Allocated storage in GB."
  type        = number
  default     = 20
}

variable "max_allocated_storage" {
  description = "Maximum storage in GB for autoscaling."
  type        = number
  default     = 100
}

variable "multi_az" {
  description = "Specifies if the RDS instance is multi-AZ."
  type        = bool
  default     = false
}

################################################################################
# Read replica
################################################################################

variable "create_read_replica" {
  description = "Whether to create a read replica."
  type        = bool
  default     = false
}

variable "read_replica_instance_class" {
  description = "Instance class for the read replica."
  type        = string
  default     = null
}

variable "read_replica_multi_az" {
  description = "Whether to deploy the read replica in multi-AZ mode."
  type        = bool
  default     = false
}

################################################################################
# Maintenance and backup
################################################################################

variable "maintenance_window" {
  description = "The window to perform maintenance in."
  type        = string
  default     = "Mon:00:00-Mon:03:00"
}

variable "backup_window" {
  description = "The daily time range during which automated backups are created."
  type        = string
  default     = "03:00-06:00"
}

variable "backup_retention_period" {
  description = "The number of days to retain backups."
  type        = number
  default     = 7
}

variable "skip_final_snapshot" {
  description = "Whether to skip the final snapshot when destroying the RDS instance."
  type        = bool
  default     = false
}

variable "deletion_protection" {
  description = "If the DB instance should have deletion protection enabled."
  type        = bool
  default     = true
}

################################################################################
# Monitoring
################################################################################

variable "monitoring_interval" {
  description = "The interval, in seconds, between points when Enhanced Monitoring metrics are collected. Valid values are 0, 1, 5, 10, 15, 30, 60."
  type        = number
  default     = 60
}

variable "create_monitoring_role" {
  description = "Whether to create an IAM role for RDS enhanced monitoring."
  type        = bool
  default     = true
}

variable "performance_insights_enabled" {
  description = "Specifies whether Performance Insights are enabled. Kept true by default so production never loses query-level observability by omission. AWS does NOT support the feature on db.t2.micro, db.t2.small, db.t3.micro, db.t3.small, db.t4g.micro or db.t4g.small - a plan-time precondition rejects that combination, so dev/stg stacks that use the smallest burstable class must set this to false explicitly."
  type        = bool
  default     = true
}

variable "performance_insights_retention_period" {
  description = "Amount of time in days to retain Performance Insights data. Valid values are 7, 731 (2 years) or a multiple of 31."
  type        = number
  default     = 7
}

variable "enabled_cloudwatch_logs_exports" {
  description = "List of log types to enable for exporting to CloudWatch logs."
  type        = list(string)
  default     = ["postgresql", "upgrade"]
}

variable "create_cloudwatch_log_group" {
  description = "Whether to create the CloudWatch log groups for enabled_cloudwatch_logs_exports."
  type        = bool
  default     = true
}
