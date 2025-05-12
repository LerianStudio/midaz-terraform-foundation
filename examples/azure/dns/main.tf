resource "azurerm_private_dns_zone" "main" {
  name                = var.dns_zone_name
  resource_group_name = var.resource_group_name

  tags = {
    environment = var.environment
    managed_by  = "terraform"
  }
}

resource "azurerm_private_dns_zone_virtual_network_link" "main" {
  name                  = "${var.dns_zone_name}-link"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.main.name
  virtual_network_id    = var.vnet_id
  registration_enabled  = true

  tags = {
    environment = var.environment
    managed_by  = "terraform"
  }
}

# A records
resource "azurerm_private_dns_a_record" "records" {
  for_each = { for record in var.a_records : record.name => record }

  name                = each.value.name
  zone_name           = azurerm_private_dns_zone.main.name
  resource_group_name = var.resource_group_name
  ttl                 = each.value.ttl
  records             = each.value.records

  tags = {
    environment = var.environment
    managed_by  = "terraform"
  }
}

# CNAME records
resource "azurerm_private_dns_cname_record" "records" {
  for_each = { for record in var.cname_records : record.name => record }

  name                = each.value.name
  zone_name           = azurerm_private_dns_zone.main.name
  resource_group_name = var.resource_group_name
  ttl                 = each.value.ttl
  record              = each.value.record

  tags = {
    environment = var.environment
    managed_by  = "terraform"
  }
}

# MX records
resource "azurerm_private_dns_mx_record" "records" {
  for_each = { for record in var.mx_records : record.name => record }

  name                = each.value.name
  zone_name           = azurerm_private_dns_zone.main.name
  resource_group_name = var.resource_group_name
  ttl                 = each.value.ttl

  dynamic "record" {
    for_each = each.value.records
    content {
      preference = record.value.preference
      exchange   = record.value.exchange
    }
  }

  tags = {
    environment = var.environment
    managed_by  = "terraform"
  }
}

# TXT records
resource "azurerm_private_dns_txt_record" "records" {
  for_each = { for record in var.txt_records : record.name => record }

  name                = each.value.name
  zone_name           = azurerm_private_dns_zone.main.name
  resource_group_name = var.resource_group_name
  ttl                 = each.value.ttl

  # Azure expects each TXT record value to be a single string.
  # To ensure compatibility, we join the list into one string with spaces in between.
  record {
    value = join(" ", each.value.records)
  }

  tags = {
    environment = var.environment
    managed_by  = "terraform"
  }
}
