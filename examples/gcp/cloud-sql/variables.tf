variable "project_id" {
  description = "The GCP project ID"
  type        = string
}

variable "instance_name" {
  description = "The name of the Cloud SQL instance"
  type        = string
  default     = "midaz-postgresql"
}

variable "region" {
  description = "The region for the Cloud SQL instance"
  type        = string
}

variable "zone" {
  description = "The zone for the Cloud SQL instance"
  type        = string
}

variable "instance_tier" {
  description = "The machine type for the Cloud SQL instance. Format: db-custom-{CPU}-{RAM_MB}"
  type        = string
  default     = "db-custom-2-8192" # 2 vCPU, 8GB RAM
}

variable "disk_size" {
  description = "The disk size for the Cloud SQL instance in GB"
  type        = number
  default     = 100
}

variable "high_availability" {
  description = "Whether to enable high availability (regional) deployment"
  type        = bool
  default     = false
}

variable "backup_location" {
  description = "The backup location for the Cloud SQL instance"
  type        = string
  default     = "us-central1"
}

variable "vpc_self_link" {
  description = "The self link of the VPC network"
  type        = string
}

variable "environment" {
  description = "Environment name for resource labels"
  type        = string
  default     = "production"
}

variable "db_version" {
  description = "The database version for PostgreSQL"
  type        = string
  default     = "POSTGRES_17"
}

variable "db_charset" {
  description = "The charset for PostgreSQL databases"
  type        = string
  default     = "UTF8"
}

variable "db_collation" {
  description = "The collation for PostgreSQL databases"
  type        = string
  default     = "en_US.UTF8"
}

variable "max_connections" {
  description = "Maximum number of database connections"
  type        = string
  default     = "100"
}

variable "backup_start_time" {
  description = "Start time for the daily backup"
  type        = string
  default     = "23:00"
}

variable "maintenance_window_day" {
  description = "Day of week (1-7) for maintenance window"
  type        = number
  default     = 7
}

variable "maintenance_window_hour" {
  description = "Hour of day (0-23) for maintenance window"
  type        = number
  default     = 23
}

variable "maintenance_window_update_track" {
  description = "The update track for maintenance window"
  type        = string
  default     = "stable"
}

variable "log_checkpoints" {
  description = "Enable logging of checkpoints"
  type        = string
  default     = "on"
}

variable "log_connections" {
  description = "Enable logging of connections"
  type        = string
  default     = "on"
}

variable "log_disconnections" {
  description = "Enable logging of disconnections"
  type        = string
  default     = "on"
}

variable "log_lock_waits" {
  description = "Enable logging of lock waits"
  type        = string
  default     = "on"
}

variable "log_temp_files" {
  description = "Log temporary files usage"
  type        = string
  default     = "0"
}

variable "disk_type" {
  description = "The type of data disk"
  type        = string
  default     = "PD_SSD"
}

variable "disk_autoresize" {
  description = "Configuration to increase storage size automatically"
  type        = bool
  default     = true
}

variable "disk_autoresize_limit" {
  description = "The maximum size to which storage can be automatically increased. The default value 0 specifies that there is no limit"
  type        = number
  default     = 0
}

variable "backup_retention_unit" {
  description = "The unit for the backup retention. Valid values are COUNT or TIME"
  type        = string
  default     = "COUNT"
}

variable "deletion_protection" {
  description = "Whether or not to allow Terraform to destroy the instance. Unless this field is set to false in Terraform state, a terraform destroy or terraform apply command that would delete the instance will fail"
  type        = bool
  default     = false
}
