# Azure Private DNS Zone Module

This Terraform module creates and manages an Azure Private DNS Zone with support for various record types.

## Features

- Creates a Private DNS Zone
- Links the DNS Zone to a Virtual Network
- Supports multiple DNS record types:
  - A Records
  - CNAME Records
  - MX Records
  - TXT Records

## Usage

```hcl
module "dns" {
  source = "./azure/dns"

  dns_zone_name       = "example.internal"
  resource_group_name = "my-resource-group"
  environment        = "production"
  vnet_id           = "/subscriptions/.../virtualNetworks/my-vnet"

  # Example A records
  a_records = [
    {
      name    = "web"
      ttl     = 300
      records = ["10.0.0.10"]
    }
  ]

  # Example CNAME records
  cname_records = [
    {
      name   = "app"
      ttl    = 300
      record = "web.example.internal"
    }
  ]

  # Example MX records
  mx_records = [
    {
      name = "mail"
      ttl  = 300
      records = [
        {
          preference = 10
          exchange   = "mail1.example.internal"
        }
      ]
    }
  ]

  # Example TXT records
  txt_records = [
    {
      name    = "verification"
      ttl     = 300
      records = ["verification=abc123"]
    }
  ]
}
```

## Requirements

- Azure Provider >= 2.0
- Terraform >= 0.13

## Inputs

| Name | Description | Type | Required |
|------|-------------|------|----------|
| dns_zone_name | Name of the DNS zone | string | yes |
| resource_group_name | Name of the resource group | string | yes |
| environment | Environment name for tagging | string | yes |
| vnet_id | ID of the Virtual Network to link | string | yes |
| a_records | List of A records to create | list(object) | no |
| cname_records | List of CNAME records to create | list(object) | no |
| mx_records | List of MX records to create | list(object) | no |
| txt_records | List of TXT records to create | list(object) | no |

## Outputs

| Name | Description |
|------|-------------|
| dns_zone_id | The ID of the Private DNS Zone |
| dns_zone_name | The name of the Private DNS Zone |
| vnet_link_id | The ID of the Private DNS Zone Virtual Network Link |
| a_records | Map of A records created |
| cname_records | Map of CNAME records created |
| mx_records | Map of MX records created |
| txt_records | Map of TXT records created |
