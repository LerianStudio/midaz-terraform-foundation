################################################################################
# Contract variables (identical across every Lerian datastore module)
################################################################################

variable "product" {
  description = "Lerian product this DocumentDB cluster belongs to (e.g. midaz, reporter). Use \"shared\" for the tier owned by products/shared-resources/documentdb — NOT \"lerian\", which labels the foundation (lerian-{env}-vpc, lerian-{env}-eks)."
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
  description = "\"dedicated\" creates a DocumentDB cluster for this product. \"shared\" creates nothing and only resolves the endpoints/secret of the shared cluster owned by products/shared-resources/documentdb."
  type        = string
  default     = "dedicated"

  validation {
    condition     = contains(["dedicated", "shared"], var.mode)
    error_message = "The mode must be either 'dedicated' or 'shared'."
  }
}

variable "extra_tags" {
  description = "Additional tags merged on top of the standard Lerian tag set."
  type        = map(string)
  default     = {}
}

variable "vpc_name" {
  description = "tag:Name of the VPC that hosts the cluster. When empty, defaults to \"lerian-{environment}-vpc\"."
  type        = string
  default     = ""
}

variable "subnet_tag_type" {
  description = "Value of the tag:Type used to select the subnets for the DocumentDB subnet group."
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

variable "shared_identifier" {
  description = "Override for the DocumentDB cluster identifier resolved in shared mode. Defaults to \"shared-{environment}-docdb\", which is what products/shared-resources/documentdb creates with product = \"shared\". Only needed when the shared tier was named outside this Terraform."
  type        = string
  default     = ""
}

variable "shared_secret_name" {
  description = "Override for the Secrets Manager secret name resolved in shared mode. Defaults to \"shared-{environment}-docdb/password\"."
  type        = string
  default     = ""
}

################################################################################
# Engine and sizing (migrated from the pre-v2 examples/aws/documentdb stack)
################################################################################

variable "master_username" {
  description = "Master username for the DocumentDB cluster."
  type        = string
  default     = "docdbadmin"
  sensitive   = true
}

variable "port" {
  description = "Port the DocumentDB cluster listens on."
  type        = number
  default     = 27017
}

variable "instance_class" {
  description = "Instance class for the DocumentDB instances. db.t3.medium is the SMALLEST class DocumentDB offers - the RDS micro/small sizes (db.t3.micro, db.t4g.micro, db.t4g.small, ...) do not exist for this service and are rejected by a plan-time precondition rather than ~5 minutes into the apply."
  type        = string
  default     = "db.t3.medium"
}

variable "instances_count" {
  description = "Number of instances in the DocumentDB cluster. 1 for dev, >= 2 for stg/prd."
  type        = number
  default     = 2
}

variable "engine_version" {
  description = "DocumentDB engine version. Leave null to take the AWS default for the parameter group family."
  type        = string
  default     = null
}

variable "parameter_group_family" {
  description = "DocumentDB cluster parameter group family. Must match engine_version."
  type        = string
  default     = "docdb5.0"
}

variable "documentdb_tls" {
  description = "Value of the \"tls\" cluster parameter: enabled or disabled."
  type        = string
  default     = "disabled"

  validation {
    condition     = contains(["enabled", "disabled"], var.documentdb_tls)
    error_message = "The documentdb_tls must be either 'enabled' or 'disabled'."
  }
}

variable "backup_retention_period" {
  description = "Number of days to retain automated backups."
  type        = number
  default     = 7
}

variable "preferred_backup_window" {
  description = "Daily time range during which automated backups are created."
  type        = string
  default     = "07:00-09:00"
}

variable "enabled_cloudwatch_logs_exports" {
  description = "DocumentDB log types exported to CloudWatch Logs."
  type        = list(string)
  default     = ["audit", "profiler"]
}

variable "skip_final_snapshot" {
  description = "Skip the final snapshot on destroy. true for dev, false for prd."
  type        = bool
  default     = true
}

variable "deletion_protection" {
  description = "Protect the cluster from accidental deletion. false for dev, true for prd."
  type        = bool
  default     = false
}

variable "apply_immediately" {
  description = "Apply cluster modifications immediately instead of waiting for the maintenance window."
  type        = bool
  default     = false
}

variable "kms_deletion_window_in_days" {
  description = "Waiting period before the CMK is actually deleted."
  type        = number
  default     = 10
}
