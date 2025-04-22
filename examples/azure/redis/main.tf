provider "azurerm" {
  features {}
}

resource "azurerm_resource_group" "redis" {
  name     = var.resource_group_name
  location = var.location

  tags = var.tags
}

resource "azurerm_redis_cache" "example" {
  name                = var.redis_name
  location            = azurerm_resource_group.redis.location
  resource_group_name = azurerm_resource_group.redis.name
  capacity            = var.capacity
  family              = var.family
  sku_name            = var.sku
  enable_non_ssl_port = var.enable_non_ssl_port
  minimum_tls_version = "1.2"

  redis_configuration {
    maxmemory_reserved = var.maxmemory_reserved
    maxmemory_delta    = var.maxmemory_delta
    maxmemory_policy   = var.maxmemory_policy
  }

  tags = var.tags
}
