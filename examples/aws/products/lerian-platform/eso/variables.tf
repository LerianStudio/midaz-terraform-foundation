variable "region" {
  description = "AWS region the role is created in. IAM is global, but the secret ARNs the policy scopes to are regional."
  type        = string
  default     = "us-east-1"
}

variable "product" {
  description = "Pinned to \"lerian-platform\". A pseudo-product for cluster-level roots that belong to no service — see main.tf for why they live under products/ at all."
  type        = string
  default     = "lerian-platform"

  validation {
    condition     = var.product == "lerian-platform"
    error_message = "This stack is lerian-platform. A real product gets its own directory."
  }
}

variable "environment" {
  description = "Deployment environment. One of dev, stg or prd."
  type        = string
}

variable "component" {
  description = "Component suffix for the role name, producing lerian-platform-{env}-{component}-irsa."
  type        = string
  default     = "eso"
}

variable "extra_tags" {
  description = "Additional tags merged on top of the standard Lerian tag set."
  type        = map(string)
  default     = {}
}

variable "eks_cluster_name" {
  description = "EKS cluster whose OIDC provider backs the role. Leave empty to DERIVE \"lerian-{environment}-eks\"."
  type        = string
  default     = ""
}

variable "oidc_provider_arn" {
  description = "Escape hatch overriding the OIDC provider lookup. Empty derives it from the cluster name."
  type        = string
  default     = ""
}

variable "service_account" {
  description = "Service account of the External Secrets Operator controller, \"namespace:name\". The chart's default is external-secrets/external-secrets. If the ClusterSecretStore is configured to use a DIFFERENT service account per store (ESO supports that), each one needs its own role."
  type        = string
  default     = "external-secrets:external-secrets"
}

variable "secret_path_prefixes" {
  description = "Vault prefixes ESO may read. Broad on purpose: the operator projects secrets for every workload, so a per-product scope defeats it. Narrow it only to carve the estate into several ClusterSecretStores with a role each."
  type        = list(string)
  default     = ["tenants/", "clusters/"]
}

variable "read_actions" {
  description = "Resource-scoped read actions. GetSecretValue projects the value; DescribeSecret is what ESO uses to detect a changed version and re-sync. BatchGetSecretValue is not included — no Lerian consumer uses it, and ESO falls back to per-secret reads."
  type        = list(string)
  default = [
    "secretsmanager:GetSecretValue",
    "secretsmanager:DescribeSecret",
  ]
}

variable "allow_list_secrets" {
  description = "Grant account-wide secretsmanager:ListSecrets. TRUE: ESO enumerates for find-by-name and find-by-tag ExternalSecrets and for store validation. Not scopeable by AWS."
  type        = bool
  default     = true
}

variable "kms_key_arns" {
  description = <<-EOT
    Customer managed keys ESO may decrypt with. THIS IS NOT OPTIONAL FOR MSK.

    AWS refuses an AWS-managed key on any secret associated with an MSK cluster
    through aws_msk_scram_secret_association, so _modules/streaming-msk creates its
    own CMK. ESO cannot project the SASL password without kms:Decrypt on that key,
    and the failure is an ExternalSecret stuck in SecretSyncedError while every
    other secret projects fine.

    Take the value from the msk root's scram_kms_key_arn output.
  EOT

  type    = list(string)
  default = []
}
