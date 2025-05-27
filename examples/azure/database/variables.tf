variable "location" {
  description = "Azure region where resources will be created"
  type        = string
  default     = "eastus2"
}

variable "resource_group_name" {
  description = "Name of existing the resource group"
  type        = string
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

variable "key_vault_access_policies" {
  description = "List of access policies for the Key Vault"
  type = list(object({
    object_id          = string
    secret_permissions = list(string)
  }))
  default = [
    {
      object_id          = "ec5f4491-a949-4432-804b-b82d03c15b3e" ## Atualize com o object_id do executor Terraform
      secret_permissions = ["Get", "List", "Set", "Delete", "Purge"]
    }
  ]
}

variable "key_vault_name" {
  description = "Name of the Key Vault"
  type        = string
  default     = "kv-db-midaz"
}

variable "dns_zone_name" {
  description = "Nome da Private DNS Zone para o PostgreSQL"
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
variable "key_vault_access_policies" {
  description = "List of access policies for the Key Vault"
  type = list(object({
    object_id          = string
    secret_permissions = list(string)
  }))
  default = [
    {
      object_id          = "ec5f4491-a949-4432-804b-b82d03c15b3e" ## Atualize com o object_id do executor Terraform
      secret_permissions = ["Get", "List", "Set", "Delete", "Purge"]
    }
  ]
}

