# 🧭 `azure-redis-cache` Module

This Terraform module provisions an Azure Redis Cache Premium instance with high availability using Private Endpoints in private subnets. It also configures Private DNS for internal name resolution.

---

## 📁 Module File Structure

### `main.tf`

- Imports existing subnets and private DNS zone into the virtual network.
- Creates an **Azure Redis Cache Premium** instance with customizable settings (capacity, sharding, memory policies, etc.).
- Creates **two Private Endpoints** connected to Redis in distinct private subnets to ensure high availability.
- Creates a private A record DNS entry pointing to the Private Endpoint IP.
- Ensures the private DNS zone is linked to the virtual network.
- Applies tags for resource identification and management.

### `variables.tf`

Defines input variables to customize the module:

#### Required
- `resource_group_name`: Name of the existing resource group.
- `redis_name`: Name of the Redis Cache instance.

#### Optional (with defaults)
- `location`: Azure region.
- `capacity`: Instance capacity (0-6 for Basic/Standard, 1-4 for Premium).
- `family`: Instance family (C for Basic/Standard, P for Premium).
- `sku`: Redis SKU (Basic, Standard, Premium).
- `shard_count`: Number of shards (Premium only).
- `maxmemory_reserved`, `maxmemory_delta`, `maxmemory_policy`: Redis memory configuration options.
- `enable_non_ssl_port`: Enable non-SSL port 6379.
- `tags`: Tags applied to all resources.

### `outputs.tf`

Exposes useful outputs for consumption by other modules or for reference:

- `redis_id`: ID of the Redis instance.
- `redis_hostname`: Hostname of the Redis instance.
- `redis_ssl_port`: SSL port for connecting.
- `redis_connection_string`: Primary connection string (sensitive).
- `redis_primary_key`: Primary access key (sensitive).

---
# `midaz.tfvars` Example

An example variables file for module usage:

```hcl
location              = "northcentralus"
resource_group_name   = "lerian-terraform-rg"
redis_name            = "midaz-redis-cache"
capacity              = 1
family                = "P"
sku                   = "Premium"
maxmemory_reserved    = 50
maxmemory_delta       = 50
maxmemory_policy      = "allkeys-lru"
tags = {
  Environment = "Production"
  Terraform   = "true"
}
shard_count           = 2
enable_non_ssl_port   = true
zone_redundant_enabled = false

## 🚀 Usage

1. Clone the module repository.

2. Adjust variables in a `.tfvars` file (e.g., `midaz.tfvars`).

3. Run Terraform commands:

```bash
terraform init
terraform apply -var-file="midaz.tfvars"

## ⚠️ Important Notes

- The module assumes the pre-existence of a Virtual Network, subnets, and a Resource Group.

- Private Endpoints are configured in private subnets for security and high availability.

- Sharding (`shard_count > 1`) is only supported for the Premium SKU.

- The non-SSL port (6379) can be enabled only for Basic and Standard SKUs.

- The module configures Private DNS for internal resolution of the Redis hostname.

- Ensure that the subnets have sufficient capacity and proper Network Security Groups (NSGs) to support Private Endpoints.




