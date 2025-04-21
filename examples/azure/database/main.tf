terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

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

resource "azurerm_mssql_server" "example" {
  name                         = "sql-server-example"
  resource_group_name          = azurerm_resource_group.db.name
  location                     = azurerm_resource_group.db.location
  version                      = "12.0"
  administrator_login          = "sqladmin"
  administrator_login_password = var.administrator_password

  tags = {
    Environment = "Example"
    Terraform   = "true"
  }
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
