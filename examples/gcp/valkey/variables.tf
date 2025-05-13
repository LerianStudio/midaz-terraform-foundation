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

variable "replication_mode" {
  description = "Enable or disable replication mode"
  type        = string
  default     = "true"
}

variable "vpc_self_link" {
  description = "The self link of the VPC network"
  type        = string
}

variable "subnet_name" {
  description = "The name of the subnet to connect to the Valkey instance"
  type        = string
}

variable "replica_count" {
  description = "The number of replica nodes"
  type        = number
  default     = null
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