variable "name" {
  description = "Name of the AmazonMQ broker"
  type        = string
  default     = "midaz-mq"
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
  description = "The deployment mode of the broker. Valid values: SINGLE_INSTANCE, ACTIVE_STANDBY_MULTI_AZ, CLUSTER_MULTI_AZ"
  type        = string
  default     = "SINGLE_INSTANCE"
}

variable "engine_type" {
  description = "The type of broker engine. Valid values: ActiveMQ, RabbitMQ"
  type        = string
  default     = "RabbitMQ"
}

variable "engine_version" {
  description = "The version of the broker engine"
  type        = string
  default     = "3.11.28"
}

variable "host_instance_type" {
  description = "The broker's instance type"
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
