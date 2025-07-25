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
    │   ├── valkey/
    │   └── eks/
    ├── gcp/
    │   ├── vpc/
    │   ├── cloud-dns/
    │   ├── cloud-sql/
    │   ├── valkey/
    │   └── gke/
    └── azure/
        ├── network/
        ├── dns/
        ├── database/
        ├── redis/
        └── aks/
        └── cosmosdb/
```

**Note**: Components must be created in the following order:
1. VPC/Network
2. DNS
3. Database
4. Valkey
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

# Create DynamoDB table for state locking
aws dynamodb create-table \
    --table-name terraform-state-lock \
    --billing-mode PAY_PER_REQUEST \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --region REGION

# Add tags to DynamoDB table
aws dynamodb tag-resource \
    --resource-arn arn:aws:dynamodb:REGION:ACCOUNT_ID:table/terraform-state-lock \
    --tags Key=Name,Value=terraform-state-lock Key=Environment,Value=shared Key=Project,Value=midaz
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

## Configuration Requirements

Before deploying the infrastructure, you must create and configure your variables file for each cloud component:

1. Copy the example variables file:
   ```bash
   cd examples/<provider>/<component>
   cp midaz.tfvars-example midaz.tfvars
   ```
2. Update all placeholders in `midaz.tfvars` with your actual values. This file contains essential configuration for your infrastructure deployment.

## Deployment Helper Script

A deployment helper script (`deploy.sh`) is provided to simplify the infrastructure deployment and destruction process. This script:

- Allows you to select your target cloud provider (AWS, Azure, or GCP)
- Provides options to either deploy or destroy the infrastructure
- Validates that all backend configuration placeholders have been properly updated
- Executes Terraform commands in the correct order for each component
- Provides clear, color-coded output for better visibility

## Production Credentials & Deployment

When deploying infrastructure in production environments, proper credential management is crucial for security. Here's how to handle credentials securely:

### Cloud Provider Authentication

When using the deploy script locally, we strongly recommend using cloud provider CLI authentication tools instead of raw credentials. This approach is more secure as it handles credential rotation, MFA, and token refresh automatically:

```bash
# AWS: Use AWS CLI to assume a role
aws sso login --profile your-profile
# or
aws sts assume-role --role-arn arn:aws:iam::ACCOUNT_ID:role/ROLE_NAME --role-session-name terraform

# GCP: Use gcloud authentication
gcloud auth application-default login
# For service accounts
gcloud auth activate-service-account --key-file=path/to/service-account.json

# Azure: Use Azure CLI
az login
# For service principals
az login --service-principal
```

This approach provides several benefits:
- Automatic token refresh
- Integration with SSO and MFA
- Credential rotation handling
- Secure credential storage
- Audit trail of authentication events

### CI/CD Integration

If you have an existing Terraform CI/CD pipeline:
1. Do not use the deploy script
2. Copy the relevant examples to your private Infrastructure as Code repository
3. Integrate the Terraform configurations with your existing pipeline
4. Use your CI/CD platform's secure secret management features

### Best Practices Documentation

Follow these official guides for credential management best practices:
- AWS: [Best practices for managing AWS access keys](https://docs.aws.amazon.com/general/latest/gr/aws-access-keys-best-practices.html)
- GCP: [Best practices for managing service account keys](https://cloud.google.com/iam/docs/best-practices-for-managing-service-account-keys)
- Azure: [Azure identity management security best practices](https://learn.microsoft.com/en-us/azure/security/fundamentals/identity-management-best-practices)

Key recommendations:
- Rotate credentials regularly
- Use role-based access control (RBAC)
- Enable MFA for user accounts
- Use temporary credentials when possible
- Monitor and audit credential usage
- Never commit credentials to version control

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
   - Run terraform init and plan
   - For deploy: Run terraform apply for each component in order
   - For destroy: Run terraform destroy for each component in reverse order

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
   # Disable default dependencies
   valkey:
      enabled: false

   postgresql:
      enabled: false

   ## Configure external PostgreSQL
   onboarding:
     configmap:
       DB_HOST: "postgresql.midaz.internal."
       DB_USER: "midaz"
       DB_PORT: "5432"
       DB_REPLICA_HOST: "postgresql-replica.midaz.internal."
       DB_REPLICA_USER: "midaz"
       DB_REPLICA_PORT: "5432"
       REDIS_HOST: "valkey.midaz.internal"
       REDIS_PORT: "6379"
     secrets:
        DB_PASSWORD: "<your-db-password>"
        DB_REPLICA_PASSWORD: "<your-replica-db-password>"
        REDIS_PASSWORD: "<your-redis-password>"

   transaction:
     configmap:
       DB_HOST: "postgresql.midaz.internal."
       DB_USER: "midaz"
       DB_PORT: "5432"
       DB_REPLICA_HOST: "postgresql-replica.midaz.internal."
       DB_REPLICA_USER: "midaz"
       DB_REPLICA_PORT: "5432"
       REDIS_HOST: "valkey.midaz.internal"
       REDIS_PORT: "6379"
     secrets:
       DB_PASSWORD: "<your-db-password>"
       DB_REPLICA_PASSWORD: "<your-replica-db-password>"
       REDIS_PASSWORD: "<your-redis-password>"
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
