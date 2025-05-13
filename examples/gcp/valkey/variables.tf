variable "project_id" {
  description = "The GCP project ID"
  type        = string
}

variable "instance_name" {
  description = "The name of the Valkey Redis instance"
  type        = string
  default     = "valkey-redis"
}

variable "region" {
  description = "The region for the Valkey Redis instance"
  type        = string
}

variable "memory_size_gb" {
  description = "The memory size of the instance in GB"
  type        = number
  default     = 6
}

variable "redis_configs" {
  description = "The Redis configuration parameters"
  type        = map(string)
  default     = {}
}

variable "maxmemory_policy" {
  description = "The Redis maxmemory policy"
  type        = string
  default     = "allkeys-lru"
}

variable "replication_mode" {
  description = "Enable or disable replication mode"
  type        = string
  default     = "true"
}

variable "auth_enabled" {
  description = "Indicates whether OSS Redis AUTH is enabled"
  type        = bool
  default     = true
}

variable "vpc_self_link" {
  description = "The self link of the VPC network"
  type        = string
}

variable "subnet_name" {
  description = "The name of the subnet to connect to the Valkey instance"
  type        = string
}

variable "connect_mode" {
  description = "The connection mode for the Redis instance"
  type        = string
  default     = "PRIVATE_SERVICE_ACCESS"
}

variable "transit_encryption_mode" {
  description = "The TLS mode for the Redis instance"
  type        = string
  default     = "DISABLED"
}

variable "replica_count" {
  description = "The number of replica nodes"
  type        = number
  default     = null
}

variable "read_replicas_mode" {
  description = "Read replicas mode for the instance"
  type        = string
  default     = "READ_REPLICAS_ENABLED"
}

variable "maintenance_policy_day" {
  description = "The day of week for maintenance window"
  type        = string
  default     = "SUNDAY"
}

variable "maintenance_policy_hour" {
  description = "The hour of day (0-23) for maintenance window"
  type        = number
  default     = 23
}

variable "maintenance_policy_minute" {
  description = "The minute of hour (0-59) for maintenance window"
  type        = number
  default     = 0
}

variable "environment" {
  description = "Environment name for resource labels"
  type        = string
  default     = "production"
}

variable "shard_count" {
  description = "Number of shards for the Valkey cluster"
  type        = number
  default     = 3
}

variable "node_type" {
  description = "The machine type of the Valkey instance"
  type        = string
  default     = "HIGHMEM_MEDIUM"
}

variable "engine_version" {
  description = "Version of the Valkey engine"
  type        = string
  default     = "VALKEY_8_0"
}

variable "deletion_protection_enabled" {
  description = "If true, deletion protection is enabled for the instance"
  type        = bool
  default     = false
}

variable "authorization_mode" {
  description = "The authorization mode for the Valkey instance"
  type        = string
  default     = "IAM_AUTH"
}

variable "snapshot_period_seconds" {
  description = "The period between snapshots in seconds (default: 12 hours)"
  type        = number
  default     = 43200
}