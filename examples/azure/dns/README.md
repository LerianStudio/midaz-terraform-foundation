# Private DNS

This Terraform module provisions a Private DNS Zone in Azure, links it to an existing Virtual Network, and configures multiple DNS record types including A, CNAME, MX, and TXT records.

## 📦 Features

- Creates a **Private DNS Zone** in a specified Resource Group.
- Links the DNS zone to an existing **Virtual Network**.
- Supports the creation of:
  - A records
  - CNAME records
  - MX records
  - TXT records
- Tags resources with environment and management metadata.

## 📁 Files Overview

| File            | Purpose                                                      |
|-----------------|--------------------------------------------------------------|
| `main.tf`       | Main infrastructure logic for DNS zone and records           |
| `variables.tf`  | Input variable definitions                                    |
| `outputs.tf`    | Output values for the created resources                       |
| `midaz.tfvars`  | Example values for variables used to run this module          |

## 🔧 Requirements

- Terraform >= 1.0.0
- Azure CLI authenticated or Service Principal with required permissions

## 📥 Input Variables

### Required

| Variable             | Description                          | Type   |
|----------------------|--------------------------------------|--------|
| `dns_zone_name`      | Name of the private DNS zone         | string |
| `resource_group_name`| Name of the resource group           | string |

### Optional

| Variable    | Description                            | Type    | Default      |
|-------------|----------------------------------------|---------|--------------|
| `environment` | Environment tag (for resource tagging) | string  | `"production"` |
| `a_records`   | List of A records to create           | list    | See below     |
| `cname_records` | List of CNAME records to create    | list    | See below     |
| `mx_records`   | List of MX records to create        | list    | See below     |
| `txt_records`  | List of TXT records to create       | list    | See below     |

#### Example values from `midaz.tfvars`

```hcl
dns_zone_name        = "lerian.internal"
resource_group_name  = "lerian-terraform-rg"
environment          = "production"

## 🛠️ Example Record Definitions

These are default values included in `variables.tf`, which can be overridden via `.tfvars`.

### 🔹 A Record

```hcl
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

## 🛠️ Example Record Definitions

These are default values included in `variables.tf`, which can be overridden via `.tfvars`.

### 🔹 A Record

```hcl
a_records = [
  {
    name    = "www"
    ttl     = 3600
    records = ["10.0.1.4", "10.0.1.5"]
  }
]

### 🔹 CNAME Record
hcl
Copy
Edit
cname_records = [
  {
    name   = "app"
    ttl    = 3600
    record = "app.lerian.io"
  }
]

### 🔹 MX Record

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

### 🔹 TXT Record

txt_records = [
  {
    name    = "spf"
    ttl     = 3600
    records = ["v=spf1 include:spf.lerian.io ~all"]
  }
]

## 📤 Outputs

| Output Name     | Description                                      |
|------------------|--------------------------------------------------|
| `dns_zone_id`    | ID of the created Private DNS Zone               |
| `dns_zone_name`  | Name of the Private DNS Zone                     |
| `vnet_link_id`   | ID of the DNS zone virtual network link          |
| `a_records`      | Map of created A records with their FQDNs        |
| `cname_records`  | Map of created CNAME records with their FQDNs    |
| `mx_records`     | Map of created MX records with their FQDNs       |
| `txt_records`    | Map of created TXT records with their FQDNs      |

---

## 🚀 How to Use

### 1. Initialize Terraform

```bash
terraform init
```

### 2. Apply the plan

```bash
terraform apply -var-file="midaz.tfvars"
```

Once applied, confirm the outputs and validate that the DNS records were created as expected.

---

## 🏷️ Tags

All resources include the following tags:

```hcl
tags = {
  environment = var.environment
  managed_by  = "terraform"
}
```

---

## 🧼 Cleanup

To destroy all provisioned resources:

```bash
terraform destroy -var-file="midaz.tfvars"
```




