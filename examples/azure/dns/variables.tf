variable "dns_zone_name" {
  description = "The name of the DNS zone"
  type        = string
}

variable "resource_group_name" {
  description = "The name of the resource group"
  type        = string
}

variable "environment" {
  description = "Environment name for tagging"
  type        = string
}

variable "vnet_id" {
  description = "ID of the Virtual Network to link with DNS zone"
  type        = string
}

variable "a_records" {
  description = "List of A records to create"
  type = list(object({
    name    = string
    ttl     = number
    records = list(string)
  }))
  default = []
}

variable "cname_records" {
  description = "List of CNAME records to create"
  type = list(object({
    name   = string
    ttl    = number
    record = string
  }))
  default = []
}

variable "mx_records" {
  description = "List of MX records to create"
  type = list(object({
    name = string
    ttl  = number
    records = list(object({
      preference = number
      exchange   = string
    }))
  }))
  default = []
}

variable "txt_records" {
  description = "List of TXT records to create"
  type = list(object({
    name    = string
    ttl     = number
    records = list(string)
  }))
  default = []
}
