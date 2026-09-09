# Lerian-terraform-foundation Changelog

## [1.9.1](https://github.com/LerianStudio/lerian-terraform-foundation/releases/tag/v1.9.1)

- Fixes:
  - Restrict the cert-manager role to TXT challenge records.
  - Fence the challenge name and refuse any wildcard ARN.
  
- Improvements:
  - Document what the challenge-name fence does to CNAME delegation.

Contributors: @fred, @lerian-studio-midaz-push-bot[bot]

[Compare changes](https://github.com/LerianStudio/lerian-terraform-foundation/compare/v1.9.0...v1.9.1)

---

## [1.9.0](https://github.com/LerianStudio/lerian-terraform-foundation/releases/tag/v1.9.0)

Features:
- Added `products/network/lerian-dev-zones` to enhance network configurations.

Fixes:
- Resolved an issue in AWS where the apply process would fail if the certificate had no matching validation option.
- Corrected the indexing of the `domainFilters` key and updated the `tfvars` example for clarity.

Contributors: @fred, @lerian-studio-midaz-push-bot[bot],

[Compare changes](https://github.com/LerianStudio/lerian-terraform-foundation/compare/v1.8.0...v1.9.0)

---

## [1.8.0](https://github.com/LerianStudio/lerian-terraform-foundation/releases/tag/v1.8.0)

- **Features**
  - Added consignado product roots, including Secrets Manager IRSA and the public edge.
  - Introduced the vpc-peering-requester root for the control plane.
  - Added the vpc-peering-accepter root for the app stacks.
  - Implemented the route53-delegation root for the child zones.
  - Added the oidc-cross-account-role root for the control plane.

- **Fixes**
  - Ensured the ESO role has access to the installation/ prefix where the KEK resides.
  - Corrected the custody Deny to be anchored at both ends and to this account with its eight verbs.
  - Made the borrowed S3 policies an explicit input to ensure clarity and correctness.
  - Refused narrowed custody Deny and unverified peering requests to improve security.
  - Rejected invalid apply_method at plan time to prevent runtime errors.

- **Improvements**
  - Renamed the underwriter product root to lender for better clarity.
  - Published iam_policy_names from the tenant-manager S3 root to enhance visibility.
  - Collapsed a tautological conditional in an output for code simplification.
  - Corrected documentation to accurately describe mechanisms and outputs.
  - Made TLS an invariant of every postgres root to ensure consistent security.

Contributors: @fred, @lerian-studio-midaz-push-bot[bot], @radagast-lerian[bot]

[Compare changes](https://github.com/LerianStudio/lerian-terraform-foundation/compare/v1.7.0...v1.8.0)

---

## [1.7.0](https://github.com/LerianStudio/lerian-terraform-foundation/releases/tag/v1.7.0)

- **Features:**
  - Allow peered CIDRs through the database network ACL.

- **Fixes:**
  - Refuse a non-IPv4 peer CIDR at plan time.
  - Bound the peer CIDR list to the network ACL quota.

Contributors: @fred, @lerian-studio-midaz-push-bot[bot],

[Compare changes](https://github.com/LerianStudio/lerian-terraform-foundation/compare/v1.6.0...v1.7.0)

---

## [1.6.0](https://github.com/LerianStudio/lerian-terraform-foundation/releases/tag/v1.6.0)

- **Features:**
  - Added `lerian-infra`, the Go orchestrator for Terraform roots.
  - Introduced `lerian-infra` with managed templates, secret references, and a release pipeline.
  - Rewrote `deploy.sh` for the v2 AWS layout.
  - Added AWS product stacks for various plugins and services, including `plugin-br-pix-switch`, `br-sfn`, `br-sisbajud`, `matcher`, and more.
  - Introduced AWS modules for naming, network contracts, and datastore configurations.

- **Fixes:**
  - Addressed the private DNS record by zone ID for Azure.
  - Removed committed Terraform plan files and widened the ignore pattern.
  - Generated URL-safe credentials in every AWS datastore module.

- **Improvements:**
  - Scoped the `tfsec` logging exception to the AWS state bucket.
  - Allowed AWS, GCP, and Azure as commit scopes in CI.
  - Migrated CI workflows to Blacksmith runners.

Contributors: @ferr3ira-gabriel, @ferr3ira.gabriel, @fred, @lerian-studio-midaz-push-bot[bot], @primo.ruiz.v

[Compare changes](https://github.com/LerianStudio/lerian-terraform-foundation/compare/v1.5.0...v1.6.0)

---

## [1.5.0](https://github.com/LerianStudio/lerian-terraform-foundation/releases/tag/v1.5.0)

Features:
- Added support for AmazonMQ cluster mode.
- Upgraded documentation to include details on AmazonMQ cluster mode.

Fixes:
- Addressed feedback from CodeRabbit review to improve code quality.

Improvements:
- Reorganized AmazonMQ documentation into a dedicated docs folder for better structure and accessibility.

Contributors: @ferr3ira-gabriel, @ferr3ira.gabriel

[Compare changes](https://github.com/LerianStudio/lerian-terraform-foundation/compare/v1.4.0...v1.5.0)

---

## [1.5.0](https://github.com/LerianStudio/lerian-terraform-foundation/releases/tag/v1.5.0)

- Features:
  - Added support for AmazonMQ cluster mode.
  - Upgraded documentation to include AmazonMQ cluster mode support.

- Fixes:
  - Addressed feedback from CodeRabbit review.

- Improvements:
  - Reorganized AmazonMQ documentation into a dedicated docs folder.

Contributors: @ferr3ira-gabriel, @ferr3ira.gabriel

[Compare changes](https://github.com/LerianStudio/lerian-terraform-foundation/compare/v1.4.0...v1.5.0)

---

## [1.4.0](https://github.com/LerianStudio/lerian-terraform-foundation/releases/tag/v1.4.0)

- **Features:**
  - Updated AWS instance types to newer generation (m7g) and added disclaimer for instance type selection.

[Compare changes](https://github.com/LerianStudio/lerian-terraform-foundation/compare/v1.3.0...v1.4.0)

---

## [1.3.0](https://github.com/LerianStudio/lerian-terraform-foundation/releases/tag/v1.3.0)

- **Features:**
  - Added AWS Load Balancer Controller support for EKS clusters.
  - Improved EKS configuration with additional security and networking options.

[Compare changes](https://github.com/LerianStudio/lerian-terraform-foundation/compare/v1.2.0...v1.3.0)

---

## [1.2.0](https://github.com/LerianStudio/lerian-terraform-foundation/releases/tag/v1.2.0)

- **Features:**
  - Added DocumentDB infrastructure module for MongoDB-compatible database deployments.
  - Updated EKS tfvars and addons configuration.

- **Improvements:**
  - Updated AWS EKS Terraform module to v21.0 with renamed parameters.

[Compare changes](https://github.com/LerianStudio/lerian-terraform-foundation/compare/v1.1.0...v1.2.0)

---

## [1.1.0](https://github.com/LerianStudio/lerian-terraform-foundation/releases/tag/v1.1.0)

- **Features:**
  - Created AmazonMQ module for RabbitMQ broker deployments.
  - Created DocumentDB module for MongoDB-compatible deployments.
  - Added optional TLS parameter for RDS and Valkey modules.
  - Added KMS key encryption for DocumentDB.
  - Added storage encryption for DocumentDB.
  - Added components for different cloud providers (AWS, GCP, Azure).
  - Added CosmosDB module for Azure resources.

- **Fixes:**
  - Excluded audit logging for RabbitMQ vulnerability in tfsec.
  - Removed unusable parameters from modules.

[Compare changes](https://github.com/LerianStudio/lerian-terraform-foundation/compare/v1.0.2...v1.1.0)

---

## [1.0.2](https://github.com/LerianStudio/lerian-terraform-foundation/releases/tag/v1.0.2)

- **Fixes:**
  - Fixed small issues on AWS template configurations.

[Compare changes](https://github.com/LerianStudio/lerian-terraform-foundation/compare/v1.0.1...v1.0.2)

---

## [1.0.1](https://github.com/LerianStudio/lerian-terraform-foundation/releases/tag/v1.0.1)

- **Fixes:**
  - Updated deploy script and infrastructure configurations.

- **Improvements:**
  - Updated GKE setup for ARM compatibility.

[Compare changes](https://github.com/LerianStudio/lerian-terraform-foundation/compare/v1.0.0...v1.0.1)

---

## [1.0.0](https://github.com/LerianStudio/lerian-terraform-foundation/releases/tag/v1.0.0)

- **Features:**
  - Initial release of Midaz Terraform Foundation.
  - AWS infrastructure modules: VPC, Route53, RDS, Valkey, EKS, AmazonMQ.
  - GCP infrastructure modules: VPC, Cloud DNS, Cloud SQL, Valkey, GKE.
  - Azure infrastructure modules: Network, DNS, Database, Redis, AKS.
  - Multi-cloud deployment script with interactive prompts.
  - Semantic versioning with automated releases.

- **Improvements:**
  - Enhanced security configurations across all cloud providers.
  - Standardized naming conventions for infrastructure components.

[View all changes](https://github.com/LerianStudio/lerian-terraform-foundation/commits/v1.0.0)

