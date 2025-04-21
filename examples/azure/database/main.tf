provider "azurerm" {
  features {}
}

resource "azurerm_resource_group" "db" {
  name     = "rg-db-example"
  location = "eastus2"

  tags = {
    Environment = "Example"
    Terraform   = "true"
  }
}

resource "azurerm_storage_account" "audit" {
  name                     = "sqlauditlogs${random_string.suffix.result}"
  resource_group_name      = azurerm_resource_group.db.name
  location                 = azurerm_resource_group.db.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"

  tags = {
    Environment = "Example"
    Terraform   = "true"
  }
}

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

resource "azurerm_mssql_server" "example" {
  name                          = "sql-server-example"
  resource_group_name           = azurerm_resource_group.db.name
  location                      = azurerm_resource_group.db.location
  version                       = "12.0"
  administrator_login           = "sqladmin"
  administrator_login_password  = var.administrator_password
  minimum_tls_version           = "1.2"
  public_network_access_enabled = false

  tags = {
    Environment = "Example"
    Terraform   = "true"
  }
}

resource "azurerm_mssql_server_extended_auditing_policy" "example" {
  server_id                               = azurerm_mssql_server.example.id
  storage_endpoint                        = azurerm_storage_account.audit.primary_blob_endpoint
  storage_account_access_key              = azurerm_storage_account.audit.primary_access_key
  storage_account_access_key_is_secondary = false
  retention_in_days                       = 90
}

resource "azurerm_mssql_database" "example" {
  name         = "example-db"
  server_id    = azurerm_mssql_server.example.id
  collation    = "SQL_Latin1_General_CP1_CI_AS"
  license_type = "LicenseIncluded"
  max_size_gb  = 2
  sku_name     = "Basic"

  tags = {
    Environment = "Example"
    Terraform   = "true"
  }
}
