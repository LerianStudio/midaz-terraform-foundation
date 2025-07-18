provider "azurerm" {
  features {}
}

locals {
  # Only public and private AKS subnet prefixes/names are passed to the module
  module_subnet_prefixes = concat(
    var.public_subnet_prefixes,
    var.private_aks_subnet_prefixes
  )
  module_subnet_names = concat(
    [for i in range(length(var.public_subnet_prefixes)) : "public-subnet-${i + 1}"],
    [for i in range(length(var.private_aks_subnet_prefixes)) : "private-aks-subnet-${i + 1}"]
  )
}

module "vnet" {
  source       = "Azure/network/azurerm"
  version      = "~> 5.0"
  use_for_each = true

  resource_group_name = data.azurerm_resource_group.network.name
  vnet_name           = var.vnet_name
  address_space       = var.address_space
  subnet_prefixes     = local.module_subnet_prefixes
  subnet_names        = local.module_subnet_names

  # Add service endpoints to all subnets created inside the module
  subnet_service_endpoints = {
    for name in local.module_subnet_names : name => ["Microsoft.Sql", "Microsoft.Storage"]
  }

  tags = {
    environment = var.environment
    managed_by  = "terraform"
  }
}

# Network Security Group for public subnets
resource "azurerm_network_security_group" "public" {
  name                = "${var.vnet_name}-public-nsg"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.network.name

  security_rule {
    name                       = "allow-https"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefixes    = var.allowed_ip_ranges
    destination_address_prefix = "*"
  }

  tags = {
    environment = var.environment
    managed_by  = "terraform"
  }
}

# Network Security Group for private subnets (AKS and DB)
resource "azurerm_network_security_group" "private" {
  name                = "${var.vnet_name}-private-nsg"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.network.name

  security_rule {
    name                       = "allow-internal"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = var.address_space
    destination_address_prefix = "*"
  }

  tags = {
    environment = var.environment
    managed_by  = "terraform"
  }
}

# Associate public NSG to public subnets created by the module
resource "azurerm_subnet_network_security_group_association" "public" {
  count                     = length(var.public_subnet_prefixes)
  subnet_id                 = module.vnet.vnet_subnets[count.index]
  network_security_group_id = azurerm_network_security_group.public.id
}

# Associate private NSG to private AKS subnets created by the module
resource "azurerm_subnet_network_security_group_association" "private_aks" {
  count                     = length(var.private_aks_subnet_prefixes)
  subnet_id                 = module.vnet.vnet_subnets[length(var.public_subnet_prefixes) + count.index]
  network_security_group_id = azurerm_network_security_group.private.id
}

# --- Create private DB subnets outside the module to enable subnet delegation ---

resource "azurerm_subnet" "private_db" {
  count                = length(var.private_db_subnet_prefixes)
  name                 = "private-db-subnet-${count.index + 1}"
  resource_group_name  = var.resource_group_name
  virtual_network_name = var.vnet_name
  address_prefixes     = [var.private_db_subnet_prefixes[count.index]]

  delegation {
    name = "postgresql-delegation"

    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
  depends_on = [module.vnet]
}

# Associate private NSG to private DB subnets
resource "azurerm_subnet_network_security_group_association" "private_db" {
  count                     = length(var.private_db_subnet_prefixes)
  subnet_id                 = azurerm_subnet.private_db[count.index].id
  network_security_group_id = azurerm_network_security_group.private.id
}

# --- Create private Redis subnets outside the module for Private Endpoint use ---

resource "azurerm_subnet" "private_redis" {
  count                = length(var.private_redis_subnet_prefixes)
  name                 = "private-redis-subnet-${count.index + 1}"
  resource_group_name  = var.resource_group_name
  virtual_network_name = var.vnet_name
  address_prefixes     = [var.private_redis_subnet_prefixes[count.index]]

  # Sem delegação necessária
  depends_on = [module.vnet]
}

# Associate private NSG to private Redis subnets
resource "azurerm_subnet_network_security_group_association" "private_redis" {
  count                     = length(var.private_redis_subnet_prefixes)
  subnet_id                 = azurerm_subnet.private_redis[count.index].id
  network_security_group_id = azurerm_network_security_group.private.id
}

# --- Create private CosmosDB subnets outside the module for Private Endpoint use ---

resource "azurerm_subnet" "private_cosmos" {
  count                = length(var.private_cosmos_subnet_prefixes)
  name                 = "private-cosmos-subnet-${count.index + 1}"
  resource_group_name  = var.resource_group_name
  virtual_network_name = var.vnet_name
  address_prefixes     = [var.private_cosmos_subnet_prefixes[count.index]]

  service_endpoints = ["Microsoft.AzureCosmosDB"]

  # No delegation required for CosmosDB
  depends_on = [module.vnet]
}

# Associate private NSG to private CosmosDB subnets
resource "azurerm_subnet_network_security_group_association" "private_cosmos" {
  count                     = length(var.private_cosmos_subnet_prefixes)
  subnet_id                 = azurerm_subnet.private_cosmos[count.index].id
  network_security_group_id = azurerm_network_security_group.private.id
}
