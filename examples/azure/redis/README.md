# 🧭 `azure-redis-cache` Module

This Terraform module provisions an **Azure Redis Cache Premium** instance with high availability using **Private Endpoints** in private subnets and integrates it with **Private DNS** for internal name resolution.

---

## 📁 Module File Structure

### `main.tf`

This file performs the core infrastructure tasks:

- **Creates an Azure Redis Cache Premium** instance with configurable performance settings.
- **Creates two Private Endpoints** across different subnets for high availability.
- **Imports existing private subnets** and **links the private DNS zone** to the virtual network.
- **Creates private A records** for name resolution via the Private DNS Zone.
- **Applies tags** to all provisioned resources for traceability and environment control.

### `variables.tf`

Defines the module’s input parameters.

#### Required

- `resource_group_name`: Name of the existing Azure Resource Group.
- `redis_name`: Unique name of the Redis instance.

#### Optional (with defaults)

- `location`: Azure region (default based on provider).
- `capacity`: Redis capacity (0–6 for Basic/Standard, 1–4 for Premium).
- `family`: Redis family (`C` for Basic/Standard, `P` for Premium).
- `sku`: SKU tier (`Basic`, `Standard`, `Premium`).
- `shard_count`: Number of shards for Redis clustering (Premium only).
- `maxmemory_reserved`, `maxmemory_delta`, `maxmemory_policy`: Memory tuning options.
- `enable_non_ssl_port`: Enables port 6379 (not recommended in production).
- `zone_redundant_enabled`: Enables zone redundancy for Redis Premium.
- `tags`: Custom tags for resource identification.

### `outputs.tf`

Exposes key outputs for use in other modules or external systems:

- `redis_id`: ID of the Redis Cache resource.
- `redis_hostname`: Internal DNS name for Redis access.
- `redis_ssl_port`: SSL port number for secure connections.
- `redis_connection_string`: Primary Redis connection string (**sensitive**).
- `redis_primary_key`: Primary access key (**sensitive**).

---

## 🔧 `midaz.tfvars` Example

```hcl
location                = "northcentralus"
resource_group_name     = "lerian-terraform-rg"
redis_name              = "midaz-redis-cache"
capacity                = 1
family                  = "P"
sku                     = "Premium"
maxmemory_reserved      = 50
maxmemory_delta         = 50
maxmemory_policy        = "allkeys-lru"
shard_count             = 2
enable_non_ssl_port     = true
zone_redundant_enabled  = false

tags = {
  Environment = "Production"
  Terraform   = "true"
}
```

---

## 🚀 Usage

You can deploy this module in two ways:

### ✅ Standalone Execution

Run the module in isolation:

```bash
terraform init
terraform apply -var-file="midaz.tfvars-example"
```

### 🔁 Integrated Execution with Script

Alternatively, run the complete infrastructure pipeline using the `deploy.sh` script in the root of the repository:

```bash
./deploy.sh
```

This script allows you to interactively choose the cloud provider and action (Deploy/Destroy), and it executes all modules in sequence while handling dependencies like networking and DNS automatically.

---

## 🧩 Considerations & Interdependencies

- **Dependencies**: The target Virtual Network, subnets, and Resource Group must be pre-created.
- **Private DNS**: Internal DNS resolution is enabled by linking the DNS zone to the VNet and creating A records for the Redis hostnames.
- **High Availability**: Redis Premium with Private Endpoints across subnets ensures redundancy.
- **Security**: Make sure subnets allow traffic via appropriate NSGs for Private Endpoint support.
- **Sharding Support**: Only available for Premium SKU (`shard_count > 1`).
- **Non-SSL Port**: Enabling `enable_non_ssl_port = true` is allowed for non-production workloads.
