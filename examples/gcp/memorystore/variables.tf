variable "project_id" {
  description = "The GCP project ID"
  type        = string
}

variable "instance_name" {
  description = "The name of the Memorystore instance"
  type        = string
  default     = "midaz-redis"
}

variable "region" {
  description = "The region for the Memorystore instance"
  type        = string
}

variable "memory_size_gb" {
  description = "The memory size of the instance in GB"
  type        = number
  default     = 5
}

variable "high_availability" {
  description = "Whether to enable high availability deployment"
  type        = bool
  default     = false
}

variable "vpc_self_link" {
  description = "The self link of the VPC network"
  type        = string
}

variable "redis_configs" {
  description = "The Redis configuration parameters"
  type        = map(string)
  default = {
    maxmemory-policy = "allkeys-lru"
  }
}

variable "environment" {
  description = "Environment name for resource labels"
  type        = string
  default     = "production"
}
