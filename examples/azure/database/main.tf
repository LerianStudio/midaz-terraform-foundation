provider "azurerm" {
  features {}
}

resource "azurerm_resource_group" "db" {
  name     = var.resource_group_name
  location = var.location

  tags = var.tags
}

resource "azurerm_storage_account" "audit" {
  name                     = "sqlauditlogs${random_string.suffix.result}"
  resource_group_name      = azurerm_resource_group.db.name
  location                 = azurerm_resource_group.db.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"

  tags = var.tags
}

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

resource "azurerm_mssql_server" "example" {
  name                          = var.server_name
  resource_group_name           = azurerm_resource_group.db.name
  location                      = azurerm_resource_group.db.location
  version                       = "12.0"
  administrator_login           = var.administrator_login
  administrator_login_password  = var.administrator_password
  minimum_tls_version           = "1.2"
  public_network_access_enabled = false

  tags = var.tags
}

resource "azurerm_mssql_server_extended_auditing_policy" "example" {
  server_id                               = azurerm_mssql_server.example.id
  storage_endpoint                        = azurerm_storage_account.audit.primary_blob_endpoint
  storage_account_access_key              = azurerm_storage_account.audit.primary_access_key
  storage_account_access_key_is_secondary = false
  retention_in_days                       = 90
}

resource "azurerm_mssql_database" "example" {
  name         = var.database_name
  server_id    = azurerm_mssql_server.example.id
  collation    = "SQL_Latin1_General_CP1_CI_AS"
  license_type = "LicenseIncluded"
  max_size_gb  = var.max_size_gb
  sku_name     = var.database_sku

  tags = var.tags
}
