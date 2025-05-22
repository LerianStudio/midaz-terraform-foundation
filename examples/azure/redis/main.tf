provider "azurerm" {
  features {}
}

#######################################################
# IMPORT EXISTING SUBNETS/RG/DNS ZONE (VNet required) #
#######################################################

data "azurerm_virtual_network" "vnet" {
  name                = "midaz-vnet"
  resource_group_name = "lerian-terraform-rg"
}

data "azurerm_subnet" "subnet_redis_1" {
  name                 = "private-redis-subnet-1"
  virtual_network_name = data.azurerm_virtual_network.vnet.name
  resource_group_name  = "lerian-terraform-rg"
}

data "azurerm_subnet" "subnet_redis_2" {
  name                 = "private-redis-subnet-2"
  virtual_network_name = data.azurerm_virtual_network.vnet.name
  resource_group_name  = "lerian-terraform-rg"
}

data "azurerm_resource_group" "redis" {
  name = "lerian-terraform-rg"
}

data "azurerm_private_dns_zone" "redis" {
  name                = "lerian.internal"
  resource_group_name = "lerian-terraform-rg"
}

############################################
#        AZURE REDIS CACHE                 #
############################################

resource "azurerm_redis_cache" "example" {
  name                = var.redis_name
  location            = var.location
  resource_group_name = var.resource_group_name
  capacity            = var.capacity
  family              = var.family
  sku_name            = var.sku
  minimum_tls_version = "1.2"
  shard_count         = var.shard_count

  public_network_access_enabled = false

  redis_configuration {
    maxmemory_reserved = var.maxmemory_reserved
    maxmemory_delta    = var.maxmemory_delta
    maxmemory_policy   = var.maxmemory_policy
  }

  tags = var.tags
}

resource "azurerm_private_endpoint" "redis" {
  name                = "${var.redis_name}-pe-1"
  location            = var.location
  resource_group_name = data.azurerm_private_dns_zone.redis.resource_group_name
  subnet_id           = data.azurerm_subnet.subnet_redis_1.id

  private_service_connection {
    name                           = "${var.redis_name}-psc-1"
    private_connection_resource_id = azurerm_redis_cache.example.id
    is_manual_connection           = false
    subresource_names              = ["redisCache"]
  }
}

resource "azurerm_private_endpoint" "redis_2" {
  name                = "${var.redis_name}-pe-2"
  location            = var.location
  resource_group_name = data.azurerm_private_dns_zone.redis.resource_group_name
  subnet_id           = data.azurerm_subnet.subnet_redis_2.id

  private_service_connection {
    name                           = "${var.redis_name}-psc-2"
    private_connection_resource_id = azurerm_redis_cache.example.id
    is_manual_connection           = false
    subresource_names              = ["redisCache"]
  }
}

# 🔄 Substituído o recurso pelo data block:
data "azurerm_private_dns_zone_virtual_network_link" "redis" {
  name                  = "${data.azurerm_private_dns_zone.redis.name}-link"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = data.azurerm_private_dns_zone.redis.name
}

resource "azurerm_private_dns_a_record" "redis" {
  name                = var.redis_name
  zone_name           = data.azurerm_private_dns_zone.redis.name
  resource_group_name = data.azurerm_private_dns_zone.redis.resource_group_name
  ttl                 = 300
  records             = [azurerm_private_endpoint.redis.private_service_connection[0].private_ip_address]

  depends_on = [
    azurerm_private_endpoint.redis
  ]
}