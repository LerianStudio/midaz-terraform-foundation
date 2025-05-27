variable "location" {
  description = "Azure region where resources will be created"
  type        = string
  default     = "northcentralus"
}

variable "resource_group_name" {
  description = "Name of the existing resource group"
  type        = string
}

variable "redis_name" {
  description = "Name of the Redis Cache instance"
  type        = string
}

variable "capacity" {
  description = "Redis Cache capacity (0-6 for Basic/Standard, 1-4 for Premium)"
  type        = number
  default     = 1
}

variable "family" {
  description = "Redis Cache family (C for Basic/Standard, P for Premium)"
  type        = string
  default     = "P"
}

variable "sku" {
  description = "Redis Cache SKU (Basic, Standard, Premium)"
  type        = string
  default     = "Premium"
}

variable "minimum_tls_version" {
  description = "Minimum TLS version for Redis"
  type        = string
  default     = "1.2"
}

variable "public_network_access_enabled" {
  description = "Enable public network access for Redis"
  type        = bool
  default     = false
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

variable "shard_count" {
  description = "Number of shards for Redis Cluster (only Premium)"
  type        = number
  default     = 2
  validation {
    condition     = !(var.sku != "Premium" && var.shard_count > 1)
    error_message = "Sharding (shard_count > 1) is only allowed for Premium SKU."
  }
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default = {
    Environment = "Production"
    Terraform   = "true"
  }
}

variable "pe_1_name" {
  description = "Name of the first Redis Private Endpoint"
  type        = string
  default     = "redis-pe-1"
}

variable "pe_2_name" {
  description = "Name of the second Redis Private Endpoint"
  type        = string
  default     = "redis-pe-2"
}

variable "psc_1_name" {
  description = "Name of the first Redis Private Service Connection"
  type        = string
  default     = "redis-psc-1"
}

variable "psc_2_name" {
  description = "Name of the second Redis Private Service Connection"
  type        = string
  default     = "redis-psc-2"
}

variable "dns_zone_link_name" {
  description = "Name of the Private DNS Zone VNet link"
  type        = string
  default     = "redis-dns-zone-link"
}

variable "redis_dns_ttl" {
  description = "TTL for the Redis private DNS A record"
  type        = number
  default     = 300
}