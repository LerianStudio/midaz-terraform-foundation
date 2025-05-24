# 🧭 `private-dns` Module

This Terraform module provisions a Private DNS Zone in Azure, links it to an existing Virtual Network, and configures multiple DNS record types including A, CNAME, MX, and TXT records. It is designed to integrate seamlessly with other modules in the Midaz infrastructure stack.

---

## 📁 Module File Structure

### `main.tf`

This is the core of the module. It performs the following:

- **Creates a Private DNS Zone** in the specified Azure Resource Group.
- **Links the DNS zone to a Virtual Network** to enable name resolution for connected resources.
- **Creates DNS records** (A, CNAME, MX, and TXT) as specified.
- **Tags all resources** with environment metadata for traceability.

### `variables.tf`

Defines the module’s input parameters, including:

- `dns_zone_name`: Name of the DNS zone (e.g., `lerian.internal`).
- `resource_group_name`: Name of the existing Azure Resource Group.
- `environment`: Tag for identifying the environment (default = `"production"`).
- `a_records`: List of A records (name, TTL, and IP addresses).
- `cname_records`: List of CNAME records (alias and canonical name).
- `mx_records`: List of MX records (for mail routing).
- `txt_records`: List of TXT records (for SPF, domain ownership, etc.).

### `outputs.tf`

Exposes critical output values for inter-module dependencies, such as:

- `dns_zone_id`: ID of the created Private DNS Zone.
- `dns_zone_name`: Name of the DNS Zone.
- `vnet_link_id`: ID of the DNS zone virtual network link.
- `a_records`, `cname_records`, `mx_records`, `txt_records`: Maps of created records with their FQDNs.

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

You can deploy this module in two distinct ways depending on your workflow.


### ✅ Standalone Execution

To deploy only the DNS stack:

Navigate to the module directory:

1. Navigate to the module directory:
   ```bash
   cd network
   terraform init
   terraform apply -var-file=midaz.tfvars-example

🔁 **Integrated Execution with Script

Alternatively, you can run the entire infrastructure pipeline using the deploy.sh script located at the root of the repository. This script provides an interactive terminal experience where you choose the cloud provider (AWS, Azure, or GCP) and the action (Deploy or Destroy). Based on your choices, it sequentially initializes, plans, and applies (or destroys) each infrastructure module in the correct order.

```bash
./deploy.sh
```

This approach ensures all modules are executed consistently and that dependencies between them (e.g., private-dns depending on network) are resolved automatically. It also validates backend configuration files and presents a colored summary table showing the status and duration of each operation.

🧩 **Considerations & Interdependencies

**Prerequisite:** The target Azure Resource Group must exist prior to applying this module. The associated Virtual Network must also exist and be passed into this module for linking.

**Record Management:**
This module supports creating multiple record types. Ensure that record definitions are accurate and that DNS names do not overlap or conflict with existing zones.

**Security Model:**
Although the DNS zone itself is private, the records it contains may expose internal services. Keep sensitive internal FQDNs consistent with internal naming policies.