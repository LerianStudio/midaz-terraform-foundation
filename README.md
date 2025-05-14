# Midaz Terraform Foundation

This repository provides Terraform examples for clients and open-source users to deploy foundation infrastructure on major cloud providers (AWS, GCP, and Azure). Each resource includes comprehensive Terraform documentation and state files. The templates follow cloud provider best practices and use official Terraform modules whenever available.

## Prerequisites

- Terraform >= 1.0.0
- A cloud provider account (AWS, GCP or Azure)
- Storage bucket for Terraform state files (see below for creation instructions)
- Cloud provider CLI tools configured:
  - `aws` for Amazon Web Services
  - `gcloud` for Google Cloud Platform
  - `az` for Azure

## Important Note

This repository provides Terraform examples for deploying foundation infrastructure. Please note that we do not provide a CI/CD pipeline implementation for these Terraform configurations. Users must implement their own CI/CD pipelines according to their specific needs and requirements.

## Project Structure

```
.
├── examples/
    ├── aws/
    │   ├── vpc/
    │   ├── route53/
    │   ├── rds/
    │   ├── elasticache/
    │   └── eks/
    ├── gcp/
    │   ├── vpc/
    │   ├── cloud-dns/
    │   ├── cloud-sql/
    │   ├── memorystore/
    │   └── gke/
    └── azure/
        ├── network/
        ├── dns/
        ├── database/
        ├── redis/
        └── aks/
```

**Note**: Components must be created in the following order:
1. VPC/Network
2. DNS
3. Database
4. Redis
5. Kubernetes Cluster

## Creating State Storage

Before using these templates, you need to create a storage bucket for Terraform state files:

### AWS
```bash
# Create an S3 bucket (replace REGION and UNIQUE_BUCKET_NAME)
aws s3api create-bucket \
    --bucket UNIQUE_BUCKET_NAME \
    --region REGION \
    --create-bucket-configuration LocationConstraint=REGION

# Enable versioning
aws s3api put-bucket-versioning \
    --bucket UNIQUE_BUCKET_NAME \
    --versioning-configuration Status=Enabled

# Enable encryption
aws s3api put-bucket-encryption \
    --bucket UNIQUE_BUCKET_NAME \
    --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

# Block public access
aws s3api put-public-access-block \
    --bucket UNIQUE_BUCKET_NAME \
    --public-access-block-configuration \
    '{"BlockPublicAcls":true,"IgnorePublicAcls":true,"BlockPublicPolicy":true,"RestrictPublicBuckets":true}'
```

### Google Cloud Platform
```bash
# Create a GCS bucket
gsutil mb -l us-central1 gs://your-terraform-state-bucket

# Enable versioning
gsutil versioning set on gs://your-terraform-state-bucket
```

### Azure
```bash
# Create a resource group
az group create --name terraform-state-rg --location eastus

# Create a storage account
az storage account create --name tfstate$RANDOM --resource-group terraform-state-rg --sku Standard_LRS

# Create a container
az storage container create --name terraform-state --account-name <storage-account-name>
```

## Deployment Helper Script

A deployment helper script (`deploy.sh`) is provided to simplify the infrastructure deployment process. This script:

- Allows you to select your target cloud provider (AWS, Azure, or GCP)
- Validates that all backend configuration placeholders have been properly updated
- Executes Terraform commands in the correct order for each component
- Provides clear, color-coded output for better visibility

### Using the Script

1. Make sure you have completed all prerequisites and created the state storage
2. Update all placeholders in the backend.tf files with your actual values
3. Make the script executable:
   ```bash
   chmod +x deploy.sh
   ```
4. Run the script:
   ```bash
   ./deploy.sh
   ```
5. Select your cloud provider when prompted
6. The script will automatically:
   - Check for any remaining placeholders
   - Run terraform init, plan, and apply for each component
   - Deploy components in the correct order

### Error Handling

The script includes error handling that will:
- Stop execution if any placeholders are found in backend configurations
- Exit if any Terraform command fails
- Provide clear error messages with the component and step that failed

## Installing Midaz

After deploying the foundation infrastructure, you can install Midaz using Helm. The Helm charts are available in the [Midaz Helm Repository](https://github.com/LerianStudio/helm).

### Prerequisites

- Kubernetes cluster (EKS, GKE, or AKS) up and running
- `kubectl` configured to access your cluster
- Helm v3.x installed
- Access to Midaz Helm repository

### Installation Steps

1. Add the Midaz Helm repository:
   ```bash
   helm repo add midaz https://lerianstudio.github.io/helm
   helm repo update
   ```

2. Create a values file (`values.yaml`) with your configuration:
   ```yaml
   # Example values.yaml
   database:
     host: "db.midaz.internal"  # Route53 DNS record created by RDS module
     port: 5432
     name: "midaz"
     username: "midaz"
     # Use a secret for the password

   redis:
     host: "redis.midaz.internal"  # Route53 DNS record created by ElastiCache module
     port: 6379
     # Use a secret for the password
   ```

3. Install Midaz:
   ```bash
   helm install midaz midaz/midaz -f values.yaml
   ```

For detailed configuration options and advanced setup, please refer to the [Midaz Helm Repository](https://github.com/LerianStudio/helm).

## Security Considerations

- All Kubernetes clusters (EKS, GKE, AKS) are public by default with IP whitelisting, but we strongly recommend:
  - Using private clusters
  - Accessing Kubernetes API via VPN
  - Implementing proper RBAC
- All sensitive data should be stored in cloud provider secret management services
- Follow the principle of least privilege for service accounts

## Contributing

**IMPORTANT**: Git hooks MUST be set up before making any code changes. This ensures all commits follow our conventions and pass necessary checks.

1. First, install git hooks (required):
   ```bash
   make hooks
   ```

2. Create a new feature branch:
   ```bash
   git checkout -b feature/your-feature
   ```
3. Make changes and commit following [conventional commits](https://www.conventionalcommits.org/)
4. Create a PR to the `develop` branch
5. After testing, changes will be merged to `main`

Please read our [Contributing Guide](CONTRIBUTING.md) for details on our code of conduct and the process for submitting pull requests.

## License

This project is licensed under the Apache License 2.0 - see the [LICENSE](LICENSE) file for details.

## Support

For support, please:
1. Check the component-specific README
2. Search existing [issues](https://github.com/LerianStudio/midaz-terraform-foundation/issues)
3. Create a new issue if needed
