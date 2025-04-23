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

variable "vpc_id" {
  description = "VPC ID where ElastiCache cluster will be created"
  type        = string
}

variable "node_type" {
  description = "ElastiCache node type"
  type        = string
  default     = "cache.t3.micro"
}

variable "engine_version" {
  description = "Redis engine version"
  type        = string
  default     = "7.0"
}

variable "family" {
  description = "Redis parameter group family"
  type        = string
  default     = "redis7"
}

variable "parameters" {
  description = "A list of Redis parameters to apply"
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
  description = "Whether to create Route53 record for Redis"
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
  default     = "redis"
}

variable "dns_zone_name" {
  description = "Route53 zone name"
  type        = string
  default     = "midaz.internal"
}
