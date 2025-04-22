variable "project_id" {
  description = "The GCP project ID"
  type        = string
}

variable "dns_name" {
  description = "The name of the DNS zone"
  type        = string
  default     = "midaz-private-zone"
}

variable "dns_domain" {
  description = "The DNS domain name"
  type        = string
  default     = "midaz.internal."
}

variable "vpc_self_link" {
  description = "The self link of the VPC network"
  type        = string
}

variable "record_sets" {
  description = "List of DNS record sets to manage"
  type = list(object({
    name    = string
    type    = string
    ttl     = number
    records = list(string)
  }))
  default = []
}
