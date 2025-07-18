output "cosmos_mongo_account_id" {
  value       = azurerm_cosmosdb_account.mongo.id
  description = "ID of the Cosmos DB account"
}

output "cosmos_mongo_db_name" {
  value       = azurerm_cosmosdb_mongo_database.mongo_db.name
  description = "MongoDB database name"
}