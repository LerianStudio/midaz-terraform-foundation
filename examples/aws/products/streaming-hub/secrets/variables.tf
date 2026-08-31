variable "region" {
  description = "AWS region the role is created in. IAM is global, but the secret ARNs the policy scopes to are regional, so this must be the region the vault lives in."
  type        = string
  default     = "us-east-1"
}

variable "product" {
  description = "Pinned to \"streaming-hub\": the derived role name is the cross-stack discovery contract."
  type        = string
  default     = "streaming-hub"

  validation {
    condition     = var.product == "streaming-hub"
    error_message = "This stack is streaming-hub. A second product gets its own directory under examples/aws/products."
  }
}

variable "environment" {
  description = "Deployment environment. One of dev, stg or prd. NAMES THE IAM OBJECTS ONLY — the environment segment inside the vault paths is the application's ENV_NAME and goes in secret_path_prefixes."
  type        = string
}

variable "component" {
  description = "Component suffix for the role name, producing streaming-hub-{env}-{component}-irsa."
  type        = string
  default     = "secrets"
}

variable "extra_tags" {
  description = "Additional tags merged on top of the standard Lerian tag set."
  type        = map(string)
  default     = {}
}

variable "eks_cluster_name" {
  description = "EKS cluster whose OIDC provider backs the role. Leave empty (the default) to DERIVE \"lerian-{environment}-eks\" — the cluster belongs to infra-base and carries the \"lerian\" product label."
  type        = string
  default     = ""
}

variable "oidc_provider_arn" {
  description = "Escape hatch overriding the OIDC provider lookup. Empty (the default) derives it from the cluster name."
  type        = string
  default     = ""
}

variable "service_account" {
  description = "Kubernetes service account the role is pinned to, \"namespace:name\". THE ANNOTATION HAS TO REACH EVERY HUB POD, not only the ingest Deployment: the tenant roster is built at boot by every role, so a delivery pod without this role crashloops while ingest looks healthy. If the chart gives the roles separate service accounts, this root needs one instance per account."
  type        = string
  default     = "streaming:streaming-hub"
}

variable "secret_path_prefixes" {
  description = <<-EOT
    Vault prefixes the hub may act on. NO TRAILING "*" — the module appends it.

    THE SEGMENT AFTER "tenants/" IS THE APPLICATION'S ENV_NAME ("production" on
    this estate), not this repository's environment ("prd"). The hub rejects a
    blank or "local" ENV_NAME under multi-tenancy, so the degenerate no-env-segment
    path shape cannot occur here.

    One prefix covers both uses: the roster listing walks
    tenants/{env}/{tenantId}/{module}/kafka by NAME, and the M2M manifest fetch
    reads the value at tenants/{env}/{orgID}/streaming-hub/m2m/{target}/credentials.
  EOT

  type    = list(string)
  default = []
}

variable "read_actions" {
  description = "Resource-scoped read actions. GetSecretValue is needed ONLY for the hub's own M2M manifest credential — the tenant roster reads names, never values, so the Kafka leaves need no value grant at all."
  type        = list(string)
  default = [
    "secretsmanager:GetSecretValue",
    "secretsmanager:DescribeSecret",
  ]
}

variable "write_actions" {
  description = "Resource-scoped write actions. EMPTY, and it should stay empty: the hub writes nothing to the vault. Tenant Kafka sheets are written by tenant-manager during onboarding."
  type        = list(string)
  default     = []
}

variable "allow_list_secrets" {
  description = "Grant account-wide secretsmanager:ListSecrets. TRUE, and it is not optional in multi-tenant mode: the tenant roster IS the listing, and an empty listing makes the hub refuse to boot rather than serve zero tenants. AWS does not evaluate ListSecrets against a resource, so this necessarily carries Resource \"*\" and the hub learns every secret NAME in the account (never a value). Set false only for single-tenant BYOC, which makes no AWS call at all."
  type        = bool
  default     = true
}

variable "kms_key_arns" {
  description = "Customer managed keys the role may use. Empty is correct while the vault uses the AWS-managed key. NOTE: the hub's KEK is NOT one of these — it is an environment variable projected by External Secrets, resolved in-process, with no AWS SDK involved."
  type        = list(string)
  default     = []
}

variable "app_env_name" {
  description = <<-EOT
    The APPLICATION's environment name — the ENV_NAME the service boots with, and
    the segment inside every Secrets Manager path. "production" on this estate,
    while var.environment is "prd". They are different vocabularies and both are
    load-bearing: var.environment names the IAM objects, this names the vault.

    IT IS IMMUTABLE FROM THE FIRST WRITE. Credential references are re-parsed on
    read and demand exact scope equality, so renaming the environment makes every
    credential already stored unreadable.

    Emitted into helm_values because the chart cannot derive it and getting it
    wrong fails in a place that does not mention it.
  EOT

  type    = string
  default = "production"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*$", var.app_env_name))
    error_message = "The app_env_name must be a lowercase name, e.g. production."
  }
}
