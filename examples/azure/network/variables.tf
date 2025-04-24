variable "address_space" {
  description = "Primary address space for the virtual network"
  type        = string
  default     = "10.0.0.0/16"
}

variable "address_spaces" {
  description = "Additional address spaces for the virtual network"
  type        = list(string)
  default     = ["10.0.0.0/16"]
}

variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
}

variable "location" {
  description = "Azure region"
  type        = string
}

variable "vnet_name" {
  description = "Name of the virtual network"
  type        = string
  default     = "midaz-vnet"
}

variable "public_subnet_prefixes" {
  description = "Address prefixes for public subnets"
  type        = list(string)
  default = [
    "10.0.1.0/24",
    "10.0.2.0/24",
    "10.0.3.0/24"
  ]
}

variable "private_aks_subnet_prefixes" {
  description = "Address prefixes for private AKS subnets"
  type        = list(string)
  default = [
    "10.0.4.0/24",
    "10.0.5.0/24",
    "10.0.6.0/24"
  ]
}

variable "private_db_subnet_prefixes" {
  description = "Address prefixes for private database subnets"
  type        = list(string)
  default = [
    "10.0.7.0/24",
    "10.0.8.0/24",
    "10.0.9.0/24"
  ]
}

variable "allowed_ip_ranges" {
  description = "List of IP CIDR ranges allowed to access resources"
  type        = list(string)
  default     = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"] # Private IP ranges only
}

variable "environment" {
  description = "Environment name for resource tags"
  type        = string
  default     = "production"
}
