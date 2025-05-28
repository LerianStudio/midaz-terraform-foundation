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

variable "a_records" {
  description = "List of A records to create"
  type = list(object({
    name    = string
    ttl     = number
    records = list(string)
  }))
  default = [
    {
      name    = "www"
      ttl     = 3600
      records = ["10.0.1.4", "10.0.1.5"]
    }
  ]
}
