variable "location" {
  description = "Azure region where resources will be created"
  type        = string
  default     = "eastus2"
}

variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
  default     = "rg-db-example"
}

variable "server_name" {
  description = "Name of the SQL Server"
  type        = string
  default     = "sql-server-example"
}

variable "database_name" {
  description = "Name of the SQL Database"
  type        = string
  default     = "example-db"
}

variable "administrator_login" {
  description = "SQL Server administrator login"
  type        = string
  default     = "sqladmin"
}

variable "administrator_password" {
  description = "SQL Server administrator password"
  type        = string
  sensitive   = true
  default     = "L3rian@2024!" # Change this in production
}

variable "database_sku" {
  description = "SKU name for the database"
  type        = string
  default     = "Basic"
}

variable "max_size_gb" {
  description = "Maximum size of the database in gigabytes"
  type        = number
  default     = 2
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default = {
    Environment = "Example"
    Terraform   = "true"
  }
}
