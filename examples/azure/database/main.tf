provider "azurerm" {
  features {}
}

##############################
# KEY VAULT FOR POSTGRES    #
##############################

resource "azurerm_key_vault" "kv-db-midaz" {
  name                       = var.key_vault_name
  resource_group_name        = var.resource_group_name
  location                   = var.location
  sku_name                   = "standard"
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  purge_protection_enabled   = false
  soft_delete_retention_days = 7
  tags                       = var.tags
}

##############################
# KEY VAULT ACCESS POLICY    #
##############################

resource "azurerm_key_vault_access_policy" "kv_access_policy" {
  for_each = { for policy in var.key_vault_access_policies : policy.object_id => policy }

  key_vault_id = azurerm_key_vault.kv-db-midaz.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = each.key

  secret_permissions = each.value.secret_permissions
}

##################################
# GENERATE RANDOM PASSWORD       #
##################################

resource "random_password" "postgres_admin_password" {
  length  = 16
  special = true
  upper   = true
  lower   = true
  numeric = true
}

##################################
# STORE PASSWORD IN KEY VAULT    #
##################################

resource "azurerm_key_vault_secret" "postgres_admin_password" {
  name         = "postgres-admin-password"
  value        = random_password.postgres_admin_password.result
  key_vault_id = azurerm_key_vault.kv-db-midaz.id

  depends_on = [azurerm_key_vault_access_policy.kv_access_policy]
}

##################################
# PRIVATE DNS ZONE - POSTGRESQL  #
##################################

resource "azurerm_private_dns_zone" "postgres" {
  name                = "privatelink.postgres.database.azure.com"
  resource_group_name = var.resource_group_name
}

###########################################
# PRIVATE DNS ZONE VNET LINK - POSTGRESQL #
###########################################

resource "azurerm_private_dns_zone_virtual_network_link" "postgres" {
  name                  = "vnet-link-postgres"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.postgres.name
  virtual_network_id    = data.azurerm_virtual_network.vnet.id
  registration_enabled  = false
}

##################################
# POSTGRESQL FLEXIBLE SERVER     #
##################################

resource "azurerm_postgresql_flexible_server" "primary" {
  name                   = var.pgsql_primary_name
  resource_group_name    = var.resource_group_name
  location               = var.location
  administrator_login    = var.pgsql_admin_login
  administrator_password = azurerm_key_vault_secret.postgres_admin_password.value
  version                = "16"

  sku_name   = var.pgsql_sku
  storage_mb = var.pgsql_storage_mb

  delegated_subnet_id           = data.azurerm_subnet.subnet_db_1.id
  private_dns_zone_id           = azurerm_private_dns_zone.postgres.id
  public_network_access_enabled = false

  tags = var.tags

  depends_on = [azurerm_key_vault_secret.postgres_admin_password]
}

##################################
# POSTGRESQL REPLICA             #
##################################

resource "azurerm_postgresql_flexible_server" "replica" {
  count               = var.enable_pgsql_replica ? 1 : 0
  name                = "${var.pgsql_primary_name}-replica"
  resource_group_name = var.resource_group_name
  location            = var.location
  create_mode         = "Replica"
  source_server_id    = azurerm_postgresql_flexible_server.primary.id

  sku_name   = var.pgsql_sku
  storage_mb = var.pgsql_storage_mb

  delegated_subnet_id           = data.azurerm_subnet.subnet_db_2.id
  private_dns_zone_id           = azurerm_private_dns_zone.postgres.id
  public_network_access_enabled = false

  dynamic "high_availability" {
    for_each = var.zone_redundant_enabled ? [1] : []
    content {
      mode = "ZoneRedundant"
    }
  }
  tags = var.tags
}