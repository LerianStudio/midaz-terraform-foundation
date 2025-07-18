provider "azurerm" {
  features {}
  skip_provider_registration = true
}

resource "azurerm_cosmosdb_account" "mongo" {
  name                          = var.cosmos_account_name
  location                      = var.location
  resource_group_name           = data.azurerm_resource_group.cosmosdb.name
  offer_type                    = "Standard"
  kind                          = "MongoDB"
  public_network_access_enabled = true #
  is_virtual_network_filter_enabled = true

  consistency_policy {
    consistency_level = "Session"
  }

  capabilities {
    name = "EnableMongo"
  }

  geo_location {
    location          = var.location
    failover_priority = 0
  }

  virtual_network_rule {
    id = data.azurerm_subnet.subnet_cosmosdb_1.id
  }

  virtual_network_rule {
    id = data.azurerm_subnet.subnet_cosmosdb_2.id
  }

  tags = var.tags
}

resource "azurerm_cosmosdb_mongo_database" "mongo_db" {
  name                = var.mongo_db_name
  resource_group_name   = data.azurerm_resource_group.cosmosdb.name
  account_name        = azurerm_cosmosdb_account.mongo.name
}

resource "azurerm_cosmosdb_mongo_collection" "mongo_collection" {
  name                = var.mongo_collection_name
  resource_group_name   = data.azurerm_resource_group.cosmosdb.name
  account_name        = azurerm_cosmosdb_account.mongo.name
  database_name       = azurerm_cosmosdb_mongo_database.mongo_db.name

  shard_key  = var.mongo_shard_key
  throughput = var.mongo_throughput
  
  index {
    keys   = ["_id"]
    unique = true
  }

}

# Private DNS zone for CosmosDB MongoDB
resource "azurerm_private_dns_zone" "cosmos_mongo" {
  name                = "privatelink.mongo.cosmos.azure.com"
  resource_group_name   = data.azurerm_resource_group.cosmosdb.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "cosmos_mongo" {
  name                  = "${var.cosmos_account_name}-dns-link"
  resource_group_name   = data.azurerm_resource_group.cosmosdb.name
  private_dns_zone_name = azurerm_private_dns_zone.cosmos_mongo.name
  virtual_network_id    = data.azurerm_virtual_network.vnet.id
  registration_enabled  = false
}

# Private Endpoint in subnet 1
resource "azurerm_private_endpoint" "cosmos_mongo_1" {
  name                = "${var.cosmos_account_name}-pe-1"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.cosmosdb.name
  subnet_id           = data.azurerm_subnet.subnet_cosmosdb_1.id

  private_service_connection {
    name                           = "${var.cosmos_account_name}-psc-1"
    private_connection_resource_id = azurerm_cosmosdb_account.mongo.id
    subresource_names              = ["MongoDB"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "cosmos-mongo-dns-zone-group-1"
    private_dns_zone_ids = [azurerm_private_dns_zone.cosmos_mongo.id]
  }

  tags = var.tags
}

# Private Endpoint in subnet 2
resource "azurerm_private_endpoint" "cosmos_mongo_2" {
  name                = "${var.cosmos_account_name}-pe-2"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.cosmosdb.name
  subnet_id           = data.azurerm_subnet.subnet_cosmosdb_2.id

  private_service_connection {
    name                           = "${var.cosmos_account_name}-psc-2"
    private_connection_resource_id = azurerm_cosmosdb_account.mongo.id
    subresource_names              = ["MongoDB"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "cosmos-mongo-dns-zone-group-2"
    private_dns_zone_ids = [azurerm_private_dns_zone.cosmos_mongo.id]
  }

  tags = var.tags
}