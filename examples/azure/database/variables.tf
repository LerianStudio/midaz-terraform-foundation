variable "location" {
  description = "Azure region where resources will be created"
  type        = string
  default     = "eastus2"
}

variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
}

variable "vnet_name" {
  description = "Name of the Virtual Network used for PostgreSQL"
  type        = string
}

variable "subnet_db_1_name" {
  description = "Name of the subnet for the primary PostgreSQL server"
  type        = string
}

variable "subnet_db_2_name" {
  description = "Name of the subnet for the PostgreSQL replica server"
  type        = string
}

variable "key_vault_name" {
  description = "Name of the Key Vault"
  type        = string
  default     = "kv-db-midaz"
}

variable "key_vault_sku" {
  description = "SKU for the Key Vault"
  type        = string
  default     = "standard"
}

variable "kv_purge_protection_enabled" {
  description = "Enable purge protection for the Key Vault"
  type        = bool
  default     = false
}

variable "kv_soft_delete_retention_days" {
  description = "Soft delete retention period for the Key Vault"
  type        = number
  default     = 7
}

variable "key_vault_access_policies" {
  description = "Access policies for the Key Vault"
  type = list(object({
    object_id          = string
    secret_permissions = list(string)
  }))
  default = []
}

variable "pgsql_primary_name" {
  description = "Name of the primary PostgreSQL server"
  type        = string
}

variable "pgsql_admin_login" {
  description = "PostgreSQL administrator login"
  type        = string
  default     = "pgsqladmin"
}

variable "pgsql_password_length" {
  description = "Length of the randomly generated admin password"
  type        = number
  default     = 16
}

variable "pgsql_secret_name" {
  description = "Name of the secret to store the PostgreSQL admin password"
  type        = string
  default     = "postgres-admin-password"
}

variable "pgsql_version" {
  description = "PostgreSQL server version"
  type        = string
  default     = "16"
}

variable "pgsql_sku" {
  description = "SKU for the PostgreSQL server"
  type        = string
  default     = "GP_Standard_D2s_v3"
}

variable "pgsql_storage_mb" {
  description = "Storage size in MB for the PostgreSQL server"
  type        = number
  default     = 131072
}

variable "dns_zone_name" {
  description = "Name of the Private DNS zone for PostgreSQL"
  type        = string
}

variable "dns_zone_link_name" {
  description = "Name of the DNS zone virtual network link"
  type        = string
  default     = "vnet-link-postgres"
}

variable "enable_pgsql_replica" {
  description = "Enable PostgreSQL read replica"
  type        = bool
  default     = false
}

variable "zone_redundant_enabled" {
  description = "Enable zone redundant HA for PostgreSQL Flexible Server"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default = {
    Environment = "Example"
    Terraform   = "true"
  }
}
