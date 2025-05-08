variable "dns_zone_name" {
  description = "The name of the DNS zone"
  type        = string
  default     = "lerian.local"
}

variable "resource_group_name" {
  description = "The name of the resource group"
  type        = string
  default     = "lerian-terraform-rg"
}

variable "environment" {
  description = "Environment name for tagging"
  type        = string
  default     = "production"
}

variable "vnet_id" {
  description = "ID of the Virtual Network to link with DNS zone"
  type        = string
  default     = "/subscriptions/d4c48709-7f36-448a-a558-4a0f5229a119/resourceGroups/lerian-terraform-rg/providers/Microsoft.Network/virtualNetworks/midaz-vnet" # Alterar para o ID correto
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
