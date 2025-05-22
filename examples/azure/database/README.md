# 🧭 `azure-postgresql-flexible-server` Module

This Terraform module provisions an Azure PostgreSQL Flexible Server instance with private network access and optional read replica for high availability. It configures Private DNS for internal hostname resolution and integrates with Azure Key Vault for secure password management.

---

## 📁 Module File Structure

### `main.tf`

- Imports existing virtual network, subnets, and private DNS zone.
- Creates an **Azure PostgreSQL Flexible Server** with customizable SKU, storage, and zone redundancy.
- Generates and stores a secure PostgreSQL administrator password in Azure Key Vault.
- Creates an optional **read replica** PostgreSQL Flexible Server.
- Creates private DNS zone records and links the DNS zone to the virtual network.
- Applies tags for resource organization and management.

### `variables.tf`

Defines input variables to customize the module:

#### Required
- `resource_group_name`: Name of the existing resource group.
- `pgsql_primary_name`: Name of the primary PostgreSQL server.
- `dns_zone_name`: Private DNS zone name for hostname resolution.

#### Optional (with defaults)
- `location`: Azure region.
- `pgsql_admin_login`: PostgreSQL admin username.
- `pgsql_sku`: Server SKU name.
- `pgsql_storage_mb`: Storage size in MB.
- `key_vault_name`: Name of the Key Vault storing the admin password.
- `key_vault_access_policies`: Access policies for Key Vault.
- `enable_pgsql_replica`: Enable read replica server.
- `zone_redundant_enabled`: Enable zone redundancy for high availability.
- `tags`: Tags applied to all resources.

### `outputs.tf`

Exposes outputs for consumption by other modules or users:

- `primary_postgresql_server_id`: ID of the primary PostgreSQL server.
- `primary_postgresql_server_fqdn`: FQDN of the primary PostgreSQL server.
- `postgresql_read_replica_id`: ID of the read replica server (if enabled).
- `postgresql_read_replica_fqdn`: FQDN of the read replica (if enabled).

---

## `midaz.tfvars` Example

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

## 🚀 Usage

1. Clone this module repository.

2. Customize variables in a `.tfvars` file (e.g., `midaz.tfvars`).

3. Initialize Terraform:

```bash
terraform init

4. Review the plan:

```bash
terraform plan -var-file="midaz.tfvars"

5. Apply the configuration
```bash
terraform apply -var-file="midaz.tfvars"


## ⚠️ Important Notes

- The module expects existing Virtual Network, subnets, Resource Group, and Key Vault.

- Private network access is enforced (public network access is disabled).

- Administrator password is automatically generated and stored securely in Azure Key Vault.

- Read replica creation is optional and recommended for read scalability and high availability.

- Zone redundancy should be enabled only if supported by your Azure region.

- Ensure the virtual network and subnets have sufficient capacity and proper permissions for private endpoints and DNS linkage.