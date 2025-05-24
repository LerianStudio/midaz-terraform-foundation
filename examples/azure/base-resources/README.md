# 🏗️ `azure-base-resources` Module

This Terraform module provisions the **foundational resources** required to bootstrap infrastructure deployment in Azure. It is intended to be used as the first module in the deployment pipeline.

---

## 📁 Module File Structure

### `provider.tf`

- Configures the **AzureRM provider** with an alias (`sponsorship`).
- Uses client credentials (`client_id`, `client_secret`, `tenant_id`, `subscription_id`) passed via variables.

### `storage.tf`

- Creates a **Resource Group** to host infrastructure resources.
- Provisions a **globally unique Storage Account** used to store the Terraform state or other infrastructure assets.
- Creates a **private Blob Storage Container** (named `terraform-state`) within the Storage Account.

---

## 🔧 `midaz.tfvars` Example

```hcl
ARM_SUBSCRIPTION_ID = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
ARM_CLIENT_ID       = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
ARM_CLIENT_SECRET   = "your-client-secret"
ARM_TENANT_ID       = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

---

## 🚀 Usage

1. Clone this module repository.

2. Export Azure credentials via environment variables or define them in a `.tfvars` file.

3. Initialize and apply the module:

```bash
terraform init
terraform apply -var-file="midaz.tfvars"
```

This module is typically used to create the base infrastructure required for provisioning resources and storing remote Terraform state in Azure.

---

## 🧩 Considerations & Interdependencies

- The **Storage Account name must be globally unique** across Azure.
- This module is usually applied **before any other** to set up the Terraform backend.
- The output of this module (Storage Account and container) is often used to configure the Terraform **remote backend** block in other modules.