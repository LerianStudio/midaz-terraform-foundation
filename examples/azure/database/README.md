# 🐘 `azure-postgresql-flexible-server` Terraform Module

This Terraform module provisions an **Azure PostgreSQL Flexible Server** with private access and secure credentials. It supports optional read replica deployment, integrates with **Azure Key Vault** for password management, and configures **Private DNS** for internal hostname resolution.

---

## 📦 Module Structure

### `main.tf`

- Imports existing **Virtual Network**, subnets, and **Private DNS Zone**.
- Creates the **Primary PostgreSQL Flexible Server** with customizable:
  - SKU and storage.
  - Zone redundancy.
  - Private access only (no public IP).
- Generates a secure admin password and stores it in **Azure Key Vault**.
- Optionally creates a **Read Replica** for high availability and scale-out reads.
- Creates **Private DNS A Records** for FQDN resolution.
- Applies tagging to all resources.

### `variables.tf`

#### 🔹 Required

- `resource_group_name`: Existing resource group name.
- `pgsql_primary_name`: Name of the primary PostgreSQL server.
- `dns_zone_name`: Private DNS zone name for hostname resolution.

#### 🔸 Optional (with defaults)

- `location`: Azure region for resource provisioning.
- `pgsql_admin_login`: Admin username (default: `pgsqladmin`).
- `pgsql_sku`: SKU name (e.g., `GP_Standard_D2s_v3`).
- `pgsql_storage_mb`: Storage size in MB (e.g., `131072` for 128 GB).
- `key_vault_name`: Name of the Azure Key Vault to store the password.
- `key_vault_access_policies`: List of access policies to assign.
- `enable_pgsql_replica`: Whether to create a read replica (default: `false`).
- `zone_redundant_enabled`: Enable zone redundancy (default: `false`).
- `tags`: Tags for all resources (e.g., `Environment`, `Owner`, etc.).

### `outputs.tf`

Exposes key values:

- `primary_postgresql_server_id`
- `primary_postgresql_server_fqdn`
- `postgresql_read_replica_id` (if enabled)
- `postgresql_read_replica_fqdn` (if enabled)

---

## 🧪 Example: `midaz.tfvars`

```hcl
location                = "northcentralus"
resource_group_name     = "lerian-terraform-rg"
pgsql_primary_name      = "lerian-postgresql"
pgsql_admin_login       = "pgsqladmin"
pgsql_sku               = "GP_Standard_D2s_v3"
pgsql_storage_mb        = 131072
key_vault_name          = "kv-db-midaz"
dns_zone_name           = "lerian.internal"
enable_pgsql_replica    = true
zone_redundant_enabled  = false
tags = {
  Environment = "Production"
  Terraform   = "true"
}
```

---

## 🚀 Usage & ⚠️ Notes

1. Clone this module repository.

2. Define a `.tfvars` file (e.g., `midaz.tfvars`) with your custom values.

3. Initialize Terraform:

```bash
terraform init
```

4. Review the execution plan:

```bash
terraform plan -var-file="midaz.tfvars"
```

5. Apply the configuration:

```bash
terraform apply -var-file="midaz.tfvars"
```

---

**Important Notes:**

- The module assumes pre-existing resources:
  - Virtual Network and subnets.
  - Resource Group.
  - Azure Key Vault.

- The PostgreSQL server is deployed **without public access** — all traffic occurs over private endpoints.

- The **admin password is generated** and stored securely in **Azure Key Vault**.

- A **read replica** is optional and useful for **read scalability** and **high availability**.

- **Zone redundancy** improves resiliency but is not available in all Azure regions.

- Ensure your subnets have:
  - Proper **delegation for Microsoft.DBforPostgreSQL**.
  - Sufficient IP capacity.
  - Compatible **NSGs** to allow private endpoint traffic.

- This module automatically links the **Private DNS Zone** to the VNet and configures DNS A records for internal resolution of PostgreSQL hostnames.
