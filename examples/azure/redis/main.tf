provider "azurerm" {
  features {}
}

resource "azurerm_resource_group" "redis" {
  name     = "rg-redis-example"
  location = "eastus2"

  tags = {
    Environment = "Example"
    Terraform   = "true"
  }
}

resource "azurerm_redis_cache" "example" {
  name                = "redis-cache-example"
  location            = azurerm_resource_group.redis.location
  resource_group_name = azurerm_resource_group.redis.name
  capacity            = 1
  family              = "C"
  sku_name            = "Basic"
  minimum_tls_version = "1.2"

  redis_configuration {
    maxmemory_reserved = 50
    maxmemory_delta    = 50
    maxmemory_policy   = "allkeys-lru"
  }

  tags = {
    Environment = "Example"
    Terraform   = "true"
  }
}
