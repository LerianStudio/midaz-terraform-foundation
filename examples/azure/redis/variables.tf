variable "location" {
  description = "Azure region where resources will be created"
  type        = string
  default     = "northcentralus" # default alinhado com seu tfvars
}

variable "resource_group_name" {
  description = "Name of existing the resource group"
  type        = string
  # sem default, obrigatório passar
}

variable "redis_name" {
  description = "Name of the Redis Cache instance"
  type        = string
  # obrigatório passar
}

variable "capacity" {
  description = "Redis Cache capacity (0-6 for Basic/Standard, 1-4 for Premium)"
  type        = number
  default     = 1
}

variable "family" {
  description = "Redis Cache family (C for Basic/Standard, P for Premium)"
  type        = string
  default     = "P" # Premium por padrão
}

variable "sku" {
  description = "Redis Cache SKU (Basic, Standard, Premium)"
  type        = string
  default     = "Premium"
}

variable "enable_non_ssl_port" {
  description = "Enable the non-SSL port (6379)"
  type        = bool
  default     = false
}

variable "maxmemory_reserved" {
  description = "Reserved memory in MB"
  type        = number
  default     = 50
}

variable "maxmemory_delta" {
  description = "Memory delta in MB"
  type        = number
  default     = 50
}

variable "maxmemory_policy" {
  description = "How Redis will select what to remove when maxmemory is reached"
  type        = string
  default     = "allkeys-lru"
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default = {
    Environment = "Production"
    Terraform   = "true"
  }
}

variable "shard_count" {
  description = "Number of shards for Redis Cluster (only Premium)"
  type        = number
  default     = 2
  validation {
    condition     = !(var.sku != "Premium" && var.shard_count > 1)
    error_message = "Sharding (shard_count > 1) is only allowed for Premium SKU."
  }
}
variable "zone_redundant_enabled" {
  description = "Enable zone redundant HA for PostgreSQL Flexible Server"
  type        = bool
  default     = true
}