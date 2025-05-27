provider "azurerm" {
  features {}
}

############################################
#        AZURE REDIS CACHE                 #
############################################

resource "azurerm_redis_cache" "example" {
  name                = var.redis_name
  location            = var.location
  resource_group_name = data.azurerm_resource_group.redis.name
  capacity            = var.capacity
  family              = var.family
  sku_name            = var.sku
  minimum_tls_version = var.minimum_tls_version
  shard_count         = var.shard_count

  public_network_access_enabled = var.public_network_access_enabled

  redis_configuration {
    maxmemory_reserved = var.maxmemory_reserved
    maxmemory_delta    = var.maxmemory_delta
    maxmemory_policy   = var.maxmemory_policy
  }

  tags = var.tags
}

resource "azurerm_private_endpoint" "redis" {
  name                = var.pe_1_name
  location            = var.location
  resource_group_name = data.azurerm_private_dns_zone.redis.resource_group_name
  subnet_id           = data.azurerm_subnet.subnet_redis_1.id

  private_service_connection {
    name                           = var.psc_1_name
    private_connection_resource_id = azurerm_redis_cache.example.id
    is_manual_connection           = false
    subresource_names              = ["redisCache"]
  }
}

resource "azurerm_private_endpoint" "redis_2" {
  name                = var.pe_2_name
  location            = var.location
  resource_group_name = data.azurerm_private_dns_zone.redis.resource_group_name
  subnet_id           = data.azurerm_subnet.subnet_redis_2.id

  private_service_connection {
    name                           = var.psc_2_name
    private_connection_resource_id = azurerm_redis_cache.example.id
    is_manual_connection           = false
    subresource_names              = ["redisCache"]
  }
}

data "azurerm_private_dns_zone_virtual_network_link" "redis" {
  name                  = var.dns_zone_link_name
  resource_group_name   = data.azurerm_resource_group.redis.name
  private_dns_zone_name = data.azurerm_private_dns_zone.redis.name
}

resource "azurerm_private_dns_a_record" "redis" {
  name                = var.redis_name
  zone_name           = data.azurerm_private_dns_zone.redis.name
  resource_group_name = data.azurerm_private_dns_zone.redis.resource_group_name
  ttl                 = var.redis_dns_ttl
  records             = [azurerm_private_endpoint.redis.private_service_connection[0].private_ip_address]

  depends_on = [
    azurerm_private_endpoint.redis
  ]
}
