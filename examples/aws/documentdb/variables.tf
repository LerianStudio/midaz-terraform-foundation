variable "name" {
  description = "Name of the DocumentDB cluster"
  type        = string
  default     = "midaz-docdb"
}

variable "environment" {
  description = "Environment name for the DocumentDB cluster"
  type        = string
  default     = "<environment>"
}

variable "additional_tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "vpc_name" {
  description = "Name of the VPC where the DocumentDB cluster will be created"
  type        = string
}

variable "instance_class" {
  description = "The instance class to use for the DocumentDB instances"
  type        = string
  default     = "db.t3.medium"
}

variable "instances_count" {
  description = "The number of instances in the DocumentDB cluster"
  type        = number
  default     = 2
}

variable "master_username" {
  description = "The master username for the DocumentDB cluster"
  type        = string
  sensitive   = true
}

variable "backup_retention_period" {
  description = "The number of days to retain backups for"
  type        = number
  default     = 7
}

variable "preferred_backup_window" {
  description = "The daily time range during which automated backups are created"
  type        = string
  default     = "07:00-09:00"
}

variable "documentdb_tls" {
  description = "Enable or disable TLS for DocumentDB cluster"
  type        = string
  default     = "disabled"
}