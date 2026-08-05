variable "name" {
  description = "Name of the AmazonMQ broker"
  type        = string
  default     = "fetcher-mq"
}

variable "environment" {
  description = "Environment name for the AmazonMQ broker"
  type        = string
  default     = "<environment>"
}

variable "additional_tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "vpc_name" {
  description = "Name of the VPC where the AmazonMQ broker will be created"
  type        = string
}

variable "deployment_mode" {
  description = "The deployment mode of the broker. Valid values: SINGLE_INSTANCE, CLUSTER_MULTI_AZ. Note: ACTIVE_STANDBY_MULTI_AZ is not supported (ActiveMQ only)."
  type        = string
  default     = "SINGLE_INSTANCE"

  validation {
    condition     = contains(["SINGLE_INSTANCE", "CLUSTER_MULTI_AZ"], var.deployment_mode)
    error_message = "deployment_mode must be either 'SINGLE_INSTANCE' or 'CLUSTER_MULTI_AZ'. Note: 'ACTIVE_STANDBY_MULTI_AZ' is not supported (ActiveMQ only)."
  }
}

variable "engine_type" {
  description = "The type of broker engine. Valid values: ActiveMQ, RabbitMQ"
  type        = string
  default     = "RabbitMQ"
}

variable "engine_version" {
  description = "The version of the broker engine"
  type        = string
  default     = "3.13"
}

variable "host_instance_type" {
  description = "The broker's instance type. Note: SINGLE_INSTANCE supports mq.t3.* for dev/test, but mq.m5.large+ is recommended for production. CLUSTER_MULTI_AZ requires mq.m5.large or larger (mq.t3.* NOT supported)."
  type        = string
  default     = "mq.t3.micro"
}

variable "publicly_accessible" {
  description = "Whether to enable public access to the broker"
  type        = bool
  default     = false
}

variable "auto_minor_version_upgrade" {
  description = "Enables automatic upgrades to new minor versions for brokers."
  type        = bool
  default     = true
}

variable "mq_admin_user" {
  description = "The administrator's username for the broker"
  type        = string
  sensitive   = true
}