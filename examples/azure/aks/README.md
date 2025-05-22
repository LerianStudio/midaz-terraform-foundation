# 🧭 `azure-aks-cluster` Module

This Terraform module provisions an Azure Kubernetes Service (AKS) cluster with private network access, a default system node pool, and an optional user node pool. It integrates with Log Analytics for monitoring and uses existing Virtual Network and Subnets.

---

## 📁 Module File Structure

### `main.tf`

- Imports existing **Virtual Network**, **Subnets**, and **Resource Group**.
- Creates an **Azure Log Analytics Workspace** for AKS monitoring.
- Provisions an **Azure Kubernetes Service (AKS)** cluster with:
  - Private cluster configuration.
  - System-assigned managed identity.
  - Monitoring agent integration.
  - Calico network policy.
  - Custom service CIDR and DNS IP range.
- Defines a **default node pool** in a selected subnet.
- Adds an optional **user node pool** for infrastructure workloads in another subnet.
- Applies custom tags to all resources.

### `variables.tf`

Defines input variables to customize the module:

#### Required
- `resource_group_name`: Name of the existing resource group.
- `cluster_name`: Name of the AKS cluster.
- `kubernetes_version`: Kubernetes version to deploy.

#### Optional (with defaults)
- `location`: Azure region where resources will be deployed.
- `api_server_access_cidrs`: List of CIDR ranges allowed to access the AKS API server.
- `node_count`: Number of nodes in the system node pool.
- `node_vm_size`: VM size for system node pool.
- `infra_node_pool_enabled`: Whether to enable an additional node pool for infrastructure.
- `infra_node_vm_size`: VM size for the infra node pool.
- `tags`: Tags applied to all resources.

### `outputs.tf`

Exposes outputs for consumption by other modules or users:

- `aks_cluster_id`: ID of the AKS cluster.
- `aks_cluster_name`: Name of the AKS cluster.
- `aks_kube_config`: Kubeconfig block for the AKS cluster.
- `aks_node_resource_group`: Name of the node resource group created by AKS.

---

## `midaz.tfvars` Example

```hcl
location                    = "eastus"
resource_group_name         = "lerian-terraform-rg"
cluster_name                = "lerian-aks"
kubernetes_version          = "1.29.2"
api_server_access_cidrs     = ["0.0.0.0/0"]
node_count                  = 2
node_vm_size                = "Standard_DS2_v2"
infra_node_pool_enabled     = true
infra_node_vm_size          = "Standard_DS2_v2"
tags = {
  Environment = "Production"
  Terraform   = "true"
}

### 🚀 Usage

1. Clone this module repository.

2. Customize variables in a `.tfvars` file (e.g., `midaz.tfvars`).

3. Initialize Terraform:

```bash
terraform init

4. Review the plan:

```bash
terraform plan -var-file="midaz.tfvars"

5. Apply the configuration
```bash
terraform apply -var-file="midaz.tfvars"

### ⚠️ Important Notes

- The module expects existing **Virtual Network**, **Subnets**, and **Resource Group**.
- The AKS cluster is **private by default** (API server accessible only through specified CIDRs or private endpoints).
- A **Log Analytics Workspace** is created for AKS monitoring integration.
- The **infra node pool** is optional and useful for running infrastructure components (e.g., ingress controllers, monitoring agents).
- Ensure required permissions to deploy managed identities, private endpoints, and role assignments in the target resource group.
- Kubernetes version must match one of the supported AKS versions.
