# GCP Infrastructure Examples for Midaz

This directory contains Terraform examples for deploying Midaz infrastructure components on Google Cloud Platform (GCP). Each subdirectory represents a different infrastructure component that can be deployed independently or as part of a complete infrastructure stack.

## Components

### VPC Network (`vpc/`)
- Creates a Virtual Private Cloud (VPC) network
- Configures subnets for different components (GKE, CloudSQL, etc.)
- Sets up firewall rules and network peering
- Manages IP address ranges for services and pods

### Google Kubernetes Engine (`gke/`)
- Deploys a GKE cluster for running Midaz microservices
- Features:
  - Regional cluster deployment for high availability
  - Node auto-scaling capabilities
  - Configurable node pools with custom machine types
  - Network policy support
  - Pod security policy configuration

**Important Notes:**
- The current version creates a public cluster endpoint with IP whitelisting for kubectl access
- For production environments, it is strongly recommended to:
  - Use a private cluster configuration
  - Access the cluster through a VPN for enhanced security
  - Follow the principle of least privilege for network access

### Cloud SQL (`cloud-sql/`)
- Provisions PostgreSQL instances for Midaz data storage
- Features:
  - High-availability configuration
  - Automated backups
  - Secure secret management through Secret Manager
  - Custom user creation and management

**Important Note:**
- TLS encryption in transit is currently not enabled as Midaz does not yet support it
- TLS support is planned and will be included in future Midaz releases

### Valkey (`valkey/`)
- Manages secrets and configuration for Midaz components
- Integrates with Google Secret Manager
- Handles encryption keys and sensitive data

**Important Note:**
- TLS encryption in transit is currently not enabled as Midaz does not yet support it
- TLS support is planned and will be included in future releases

### Cloud DNS (`cloud-dns/`)
- Manages DNS zones and records
- Configures DNS for internal service discovery
- Supports external DNS resolution for public services

## Roadmap Components

The following components are not yet included in the Terraform templates but are planned for future releases:

### RabbitMQ
- Message broker for asynchronous communication
- Will be added in future versions
- Currently must be provisioned separately

### MongoDB
- NoSQL database for specific Midaz components
- Will be added in future versions
- Currently must be provisioned separately

## Terraform File Structure

Each component directory contains its own:
- `main.tf` - Main Terraform configuration
- `variables.tf` - Input variables definition
- `outputs.tf` - Output values
- `versions.tf` - Provider and version constraints
- `backend.tf` - State backend configuration

## Security Considerations

- All sensitive data is stored in Google Secret Manager
- Components are deployed with minimal required permissions
- Network access is restricted through firewall rules
- Regular security updates are applied through node auto-upgrade
- Production deployments should use private endpoints where possible

## Support

For issues and feature requests, please contact the Midaz infrastructure team or create an issue in the project repository.
