variable "name" {
  description = "Base name for resources"
  type        = string
  default     = "midaz-foundation"
}

variable "environment" {
  description = "Deployment environment"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.50.0.0/16"
}

variable "availability_zones" {
  description = "List of availability zones"
  type        = list(string)
  default     = ["us-east-2a", "us-east-2b", "us-east-2c"]
}

variable "enable_nat_gateway" {
  description = "Should be true if you want to provision NAT Gateways for each of your private networks"
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = "Should be true if you want to provision a single shared NAT Gateway across all of your private networks"
  type        = bool
  default     = false
}

variable "one_nat_gateway_per_az" {
  description = "Should be true if you want only one NAT Gateway per availability zone"
  type        = bool
  default     = false
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

variable "enable_dns_hostnames" {
  description = "Should be true if you want to enable DNS hostnames in the VPC"
  type        = bool
  default     = true
}

variable "enable_dns_support" {
  description = "Should be true if you want to enable DNS support in the VPC"
  type        = bool
  default     = true
}

variable "additional_tags" {
  description = "Tags additional for resources use."
  type        = map(string)
  default     = {}
}

variable "resource_tags" {
  description = "Tags for specific resource types"
  type        = map(string)
  default = {
    vpc          = "vpc"
    vpc_endpoint = "vpc-endpoint"
    network_acl  = "network-acl"
  }
}