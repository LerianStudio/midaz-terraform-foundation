variable "name" {
  description = "Base name for resources"
  type        = string
}

variable "environment" {
  description = "Deployment environment"
  type        = string
}

variable "username" {
  description = "Database master user"
  type        = string
  default     = "postgres"
}

variable "vpc_name" {
  description = "VPC name where RDS instance will be created"
  type        = string
}

variable "engine" {
  description = "Database engine type"
  type        = string
  default     = "postgres"
}

variable "engine_version" {
  description = "Database engine version"
  type        = string
  default     = "16.3"
}

variable "family" {
  description = "Database parameter group family"
  type        = string
  default     = "postgres16"
}

variable "major_engine_version" {
  description = "Database major engine version"
  type        = string
  default     = "16"
}

variable "instance_class" {
  description = "Instance type for the RDS instance"
  type        = string
  default     = "db.m7g.large"
}

variable "allocated_storage" {
  description = "Allocated storage in GB"
  type        = number
  default     = 20
}

variable "max_allocated_storage" {
  description = "Maximum storage in GB for autoscaling"
  type        = number
  default     = 100
}

variable "database_name" {
  description = "Name of the database to create"
  type        = string
}

variable "port" {
  description = "Database port"
  type        = number
  default     = 5432
}

variable "parameters" {
  description = "A list of DB parameters to apply"
  type        = list(map(string))
  default     = []
}

variable "multi_az" {
  description = "Specifies if the RDS instance is multi-AZ"
  type        = bool
  default     = false
}

variable "additional_tags" {
  description = "Additional tags for resources"
  type        = map(string)
  default     = {}
}

variable "dns_zone_name" {
  description = "Route53 zone name"
  type        = string
  default     = "midaz.internal"
}

variable "backup_retention_period" {
  description = "The number of days to retain backups"
  type        = number
  default     = 7
}

variable "skip_final_snapshot" {
  description = "Whether to skip final snapshot when destroying the RDS instance"
  type        = bool
  default     = false
}

variable "create_read_replica" {
  description = "Whether to create a read replica"
  type        = bool
  default     = false
}

variable "read_replica_instance_class" {
  description = "Instance class for the read replica"
  type        = string
  default     = null
}

variable "read_replica_multi_az" {
  description = "Whether to deploy read replica in multi AZ mode"
  type        = bool
  default     = false
}

# Monitoring configuration
variable "monitoring_interval" {
  description = "The interval, in seconds, between points when Enhanced Monitoring metrics are collected. Valid values are 0, 1, 5, 10, 15, 30, 60"
  type        = number
  default     = 60
}

variable "performance_insights_enabled" {
  description = "Specifies whether Performance Insights are enabled"
  type        = bool
  default     = true
}

variable "performance_insights_retention_period" {
  description = "Amount of time in days to retain Performance Insights data. Valid values are 7, 731 (2 years) or a multiple of 31"
  type        = number
  default     = 7
}

variable "deletion_protection" {
  description = "If the DB instance should have deletion protection enabled"
  type        = bool
  default     = true
}

variable "maintenance_window" {
  description = "The window to perform maintenance in"
  type        = string
  default     = "Mon:00:00-Mon:03:00"
}

variable "backup_window" {
  description = "The daily time range during which automated backups are created"
  type        = string
  default     = "03:00-06:00"
}

variable "enabled_cloudwatch_logs_exports" {
  description = "List of log types to enable for exporting to CloudWatch logs"
  type        = list(string)
  default     = ["postgresql", "upgrade"]
}

variable "create_cloudwatch_log_group" {
  description = "Whether to create CloudWatch log group"
  type        = bool
  default     = true
}

variable "create_monitoring_role" {
  description = "Whether to create an IAM role for RDS enhanced monitoring"
  type        = bool
  default     = true
}
