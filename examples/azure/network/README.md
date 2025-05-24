# 📡 `Network` Module

This Terraform module provisions the complete virtual network architecture required for the Midaz environment on Microsoft Azure. It establishes a secure, modular, and scalable network foundation by deploying:

- A Virtual Network (VNet)
- Public and private subnets (for AKS, PostgreSQL, and Redis)
- Network Security Groups (NSGs) with ingress and egress controls
- Subnet delegations and support for private endpoints

---

## 📁 Module File Structure

### `main.tf`

This is the core of the module. It performs the following:

- **VNet provisioning** using the official Azure Network module.
- **Creation of subnets**:
  - Public subnets for resources requiring internet-facing access (e.g., Bastion).
  - Private subnets for services such as AKS, databases, and Redis.
- **Definition of Network Security Groups (NSGs)**:
  - Public NSGs allow inbound HTTPS from a configurable list of IP ranges.
  - Private NSGs allow internal traffic within defined address spaces.
- **Subnet-to-NSG associations**
- **Subnet delegations**:
  - The DB subnet is delegated to `Microsoft.DBforPostgreSQL/flexibleServers`.
  - Redis subnets are isolated for private endpoint configurations.

### `variables.tf`

Defines the module’s input parameters, including:

- `address_space`: CIDR block for the VNet
- `subnet_prefixes`: CIDRs for each subnet
- `vnet_name`, `resource_group_name`, `location`: Naming and regional metadata
- `allowed_ip_ranges`: IP ranges allowed to access public services
- `environment`: Used for tagging and environment segregation

### `outputs.tf`

Exposes critical output values for inter-module dependencies, such as:

- VNet name, ID, and location
- Subnet IDs for AKS, public services, databases
- NSG IDs for both public and private zones

These outputs are designed to be consumed by downstream modules such as `bastion`, `aks`, `database`, etc.

### `midaz.tfvars`

A sample `tfvars` configuration file for this module:

resource_group_name = "lerian-terraform-rg"
location            = "North Central US"
vnet_name           = "midaz-vnet"
environment         = "production"
allowed_ip_ranges   = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]

## 🚀 Usage

You can deploy this module in two distinct ways depending on your workflow.

### ✅ Standalone Execution

To deploy only the network stack:

1. Navigate to the module directory:
   ```bash
   cd network
   terraform init
   terraform apply -var-file=midaz.tfvars-example

🔁 **Integrated Execution with Script**

Alternatively, you can run the entire infrastructure pipeline using the `deploy.sh` script located at the root of the repository. This script provides an interactive terminal experience where you choose the cloud provider (AWS, Azure, or GCP) and the action (Deploy or Destroy). Based on your choices, it sequentially initializes, plans, and applies (or destroys) each infrastructure module in the correct order.

```bash
./deploy.sh
```

This approach ensures all modules are executed consistently and that dependencies between them (e.g., DNS depending on networking) are resolved automatically. It also validates backend configuration files and presents a colored summary table showing the status and duration of each operation.

🧩 **Considerations & Interdependencies**

**Prerequisite:** The target Azure Resource Group must exist prior to applying this module.

**Delegations:**

- The DB subnet is explicitly delegated for PostgreSQL Flexible Server deployments.

**Private Endpoints:**  
Redis-related subnets are provisioned with private endpoints in mind but are not delegated to any service.

**Security Model:**  
NSGs enforce a secure-by-default policy, where public access is restricted to specific IP ranges and internal communication is tightly scoped.

