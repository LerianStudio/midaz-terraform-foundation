locals {
  all_subnet_prefixes = concat(
    var.public_subnet_prefixes,
    var.private_aks_subnet_prefixes,
    var.private_db_subnet_prefixes
  )
  all_subnet_names = concat(
    [for i in range(length(var.public_subnet_prefixes)) : "public-subnet-${i + 1}"],
    [for i in range(length(var.private_aks_subnet_prefixes)) : "private-aks-subnet-${i + 1}"],
    [for i in range(length(var.private_db_subnet_prefixes)) : "private-db-subnet-${i + 1}"]
  )
}

module "vnet" {
  source       = "Azure/network/azurerm"
  version      = "~> 5.0"
  use_for_each = true

  resource_group_name = var.resource_group_name
  vnet_name           = var.vnet_name
  address_space       = var.address_space[*]
  address_spaces      = var.address_spaces[*]
  subnet_prefixes     = local.all_subnet_prefixes
  subnet_names        = local.all_subnet_names

  subnet_service_endpoints = {
    for name in local.all_subnet_names : name => ["Microsoft.Sql", "Microsoft.Storage"]
  }

  tags = {
    environment = var.environment
    managed_by  = "terraform"
  }
}

# Create Network Security Groups
resource "azurerm_network_security_group" "public" {
  name                = "${var.vnet_name}-public-nsg"
  location            = var.location
  resource_group_name = var.resource_group_name

  security_rule {
    name                       = "allow-https"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefixes    = var.allowed_ip_ranges[*]
    destination_address_prefix = "*"
  }

  tags = {
    environment = var.environment
    managed_by  = "terraform"
  }
}

resource "azurerm_network_security_group" "private" {
  name                = "${var.vnet_name}-private-nsg"
  location            = var.location
  resource_group_name = var.resource_group_name

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

# Associate NSGs with subnets
resource "azurerm_subnet_network_security_group_association" "public" {
  count                     = length(var.public_subnet_prefixes)
  subnet_id                 = module.vnet.vnet_subnets[count.index]
  network_security_group_id = azurerm_network_security_group.public.id
}

resource "azurerm_subnet_network_security_group_association" "private_aks" {
  count                     = length(var.private_aks_subnet_prefixes)
  subnet_id                 = module.vnet.vnet_subnets[length(var.public_subnet_prefixes) + count.index]
  network_security_group_id = azurerm_network_security_group.private.id
}

resource "azurerm_subnet_network_security_group_association" "private_db" {
  count                     = length(var.private_db_subnet_prefixes)
  subnet_id                 = module.vnet.vnet_subnets[length(var.public_subnet_prefixes) + length(var.private_aks_subnet_prefixes) + count.index]
  network_security_group_id = azurerm_network_security_group.private.id
}
