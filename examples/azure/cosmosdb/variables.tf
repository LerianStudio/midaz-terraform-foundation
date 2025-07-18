variable "cosmos_account_name" {
  description = "Cosmos DB account name"
  type        = string
}

variable "mongo_db_name" {
  description = "MongoDB database name"
  type        = string
}

variable "mongo_collection_name" {
  description = "MongoDB collection name"
  type        = string
}

variable "mongo_shard_key" {
  description = "Shard key used in the collection"
  type        = string
  default     = "_id"
}

variable "mongo_throughput" {
  description = "Throughput (RU/s) of the collection"
  type        = number
  default     = 400
}
variable "location" {
  description = "Azure region where resources will be created"
  type        = string
}
variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default = {
    Environment = "Example"
    Terraform   = "true"
  }
}