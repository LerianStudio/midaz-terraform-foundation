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

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.50.0.0/16"
}

variable "flow_logs_enabled" {
  description = "Enable VPC Flow Logs"
  type        = bool
  default     = true
}

variable "vpc_endpoint_enabled" {
  description = "Enable VPC Endpoints"
  type        = bool
  default     = true
}

variable "additional_tags" {
  description = "Tags additional for resources use."
  type        = map(string)
  default     = {}
}