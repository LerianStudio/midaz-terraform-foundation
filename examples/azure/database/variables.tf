variable "location" {
  description = "Azure region where resources will be created"
  type        = string
}

variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
}

variable "vnet_name" {
  description = "Name of the existing Virtual Network"
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

# variable "kv_purge_protection_enabled" {
#   description = "Enable purge protection for the Key Vault"
#   type        = bool
#   default     = false
# }

variable "kv_soft_delete_retention_days" {
  description = "Soft delete retention period for the Key Vault"
  type        = number
  default     = 7
}

variable "key_vault_access_policies" {
  description = "List of access policies for the Key Vault"
  type = list(object({
    object_id          = string
    secret_permissions = list(string)
  }))
  default = [
    {
      object_id          = "ec5f4491-a949-4432-804b-b82d03c15b3e" # Update with the executor's object_id
      secret_permissions = ["Get", "List", "Set", "Delete", "Purge"]
    }
  ]
}

variable "pgsql_secret_name" {
  description = "Name of the secret to store the PostgreSQL admin password"
  type        = string
  default     = "postgres-admin-password"
}

variable "dns_zone_link_name" {
  description = "Name of the DNS zone virtual network link"
  type        = string
  default     = "vnet-link-postgres"
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

variable "pgsql_sku" {
  description = "SKU name for the PostgreSQL servers"
  type        = string
  default     = "GP_Standard_D2s_v3"
}

variable "pgsql_storage_mb" {
  description = "Storage size for the PostgreSQL server in MB"
  type        = number
  default     = 131072 # 128 GB storage
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default = {
    Environment = "Example"
    Terraform   = "true"
  }
}

variable "dns_zone_name" {
  description = "Name of the Private DNS Zone for PostgreSQL"
  type        = string
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

variable "pgsql_password_length" {
  description = "Length of the randomly generated admin password"
  type        = number
  default     = 16
}

variable "pgsql_version" {
  description = "PostgreSQL server version"
  type        = string
  default     = "16"
}

variable "key_vault_allowed_ips" {
  description = "List of IPs allowed to access the Key Vault"
  type        = list(string)
  default     = ["177.189.119.119/32"]
}

variable "key_vault_allowed_subnets" {
  description = "List of subnet IDs allowed to access the Key Vault"
  type        = list(string)
  default     = []
}