variable "name" {
  description = "Base name for resources"
  type        = string
  default     = "midaz-foundation"
}

variable "environment" {
  description = "Deployment environment: dev, hml, or prod"
  type        = string
  default     = "dev"
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "vpc_id" {
  description = "VPC ID where RDS instance will be created"
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
  default     = "14.7"
}

variable "family" {
  description = "Database parameter group family"
  type        = string
  default     = "postgres14"
}

variable "major_engine_version" {
  description = "Database major engine version"
  type        = string
  default     = "14"
}

variable "instance_class" {
  description = "Instance type for the RDS instance"
  type        = string
  default     = "db.t3.medium"
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

variable "username" {
  description = "Database master user"
  type        = string
  default     = "postgres"
}

variable "port" {
  description = "Database port"
  type        = number
  default     = 5432
}

variable "parameters" {
  description = "A list of DB parameters to apply"
  type = list(object({
    name  = string
    value = string
  }))
  default = []
}

variable "additional_tags" {
  description = "Additional tags for resources"
  type        = map(string)
  default     = {}
}

# DNS Variables
variable "create_dns_record" {
  description = "Whether to create Route53 record for RDS"
  type        = bool
  default     = false
}

variable "route53_zone_id" {
  description = "Route53 zone ID for DNS record"
  type        = string
  default     = ""
}

variable "dns_name" {
  description = "DNS record name (without zone name)"
  type        = string
  default     = "db"
}

variable "dns_zone_name" {
  description = "Route53 zone name"
  type        = string
  default     = "midaz.internal"
}
