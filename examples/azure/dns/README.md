# 🧭 `private-dns` Module

This Terraform module provisions a Private DNS Zone in Azure, links it to an existing Virtual Network, and configures multiple DNS record types including A, CNAME, MX, and TXT records.

---

## 📁 Module File Structure

### `main.tf`

Main infrastructure logic for DNS zone and records:
- Creates a **Private DNS Zone** in the specified Resource Group.
- Links it to a specified **Virtual Network**.
- Creates DNS records (A, CNAME, MX, TXT).
- Tags all resources with metadata (e.g., environment).

### `variables.tf`

Defines input variables used to configure the module:

#### Required
- `dns_zone_name`: Name of the private DNS zone.
- `resource_group_name`: Name of the Azure Resource Group.

#### Optional
- `environment`: Resource tag (default = `"production"`).
- `a_records`: List of A records.
- `cname_records`: List of CNAME records.
- `mx_records`: List of MX records.
- `txt_records`: List of TXT records.

### `outputs.tf`

Exposes outputs to be used by other modules or for reference:

- `dns_zone_id`: ID of the created Private DNS Zone.
- `dns_zone_name`: Name of the DNS Zone.
- `vnet_link_id`: ID of the DNS zone virtual network link.
- `a_records`: Map of created A records with their FQDNs.
- `cname_records`: Map of created CNAME records with their FQDNs.
- `mx_records`: Map of created MX records with their FQDNs.
- `txt_records`: Map of created TXT records with their FQDNs.

### `midaz.tfvars`

A sample `tfvars` configuration file for this module:

```hcl
dns_zone_name        = "lerian.internal"
resource_group_name  = "lerian-terraform-rg"
environment          = "production"

a_records = [
  {
    name    = "www"
    ttl     = 3600
    records = ["10.0.1.4", "10.0.1.5"]
  }
]

cname_records = [
  {
    name   = "app"
    ttl    = 3600
    record = "app.lerian.io"
  }
]

mx_records = [
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

txt_records = [
  {
    name    = "spf"
    ttl     = 3600
    records = ["v=spf1 include:spf.lerian.io ~all"]
  }
]

## 🚀 Usage

The script will ask you to:

**Select a cloud provider:**

- `1` for AWS  
- `2` for Azure  
- `3` for GCP  

**Select an action:**

- `1` to deploy all components  
- `2` to destroy all components  

It will then automatically deploy or destroy the following components in order:

- network  
- dns  
- database  
- redis  
- kubernetes  

> **Note:** During deployment, the script validates that backend configuration files do not contain any placeholder values (`<...>`). If placeholders are found, deployment will stop and ask you to fix them.

---

### Manual Terraform execution (alternative)

If you prefer, you can manually initialize and apply Terraform in any module folder:

```bash
terraform init
terraform apply -var-file="midaz.tfvars"



