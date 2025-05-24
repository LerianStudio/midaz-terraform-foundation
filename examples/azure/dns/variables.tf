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
  default     = "production"
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

variable "cname_records" {
  description = "List of CNAME records to create"
  type = list(object({
    name   = string
    ttl    = number
    record = string
  }))
  default = [
    {
      name   = "app"
      ttl    = 3600
      record = "app.lerian.io"
    }
  ]
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
  default = [
    {
      name = "mail"
      ttl  = 3600
      records = [
        {
          preference = 10
          exchange   = "mail.lerian.io"
        },
        {
          preference = 20
          exchange   = "backup-mail.lerian.io"
        }
      ]
    }
  ]
}

variable "txt_records" {
  description = "List of TXT records to create"
  type = list(object({
    name    = string
    ttl     = number
    records = list(string)
  }))
  default = [
    {
      name    = "spf"
      ttl     = 3600
      records = ["v=spf1 include:spf.lerian.io ~all"]
    }
  ]
}
