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

variable "deny_secret_path_patterns" {
  description = <<-EOT
    Paths this role may NOT touch, whatever the Allow says.

    THE CUSTODY PATH BELONGS HERE. secret_path_prefixes names an ENVIRONMENT, not a
    component, because the tenant roster is the listing of that whole environment.
    An environment prefix swallows
    tenants/{env}/{org}/{app}/external/{target}/credentials/versions/{uuid}, which
    is a tenant's Dataprev credential — and unlike tenant-manager, this role holds
    GetSecretValue over what it reaches.

    Only the gateway reads a custody credential. A narrower Allow is not the
    instrument: the roster needs the broad prefix. A Deny is what carves a hole out
    of a broad Allow, and in IAM it beats every Allow, including one attached to
    this role later by somebody else.

    The hub loses no function. It reads a VALUE only for its own M2M manifest
    credential under m2m/, and builds the roster from NAMES alone.
  EOT

  type    = list(string)
  default = []

  validation {
    condition     = contains(var.deny_secret_path_patterns, "tenants/*/*/*/external/")
    error_message = "tenants/*/*/*/external/ must be in deny_secret_path_patterns. This role's Allow reaches the Dataprev custody credential, which only the gateway may touch, and the module emits no Deny at all for an empty list — so omitting it plans cleanly and silently drops the carve-out. That is not hypothetical: streaming-hub/secrets shipped without it and its production role held GetSecretValue over every custody secret in the account. The gateway root is the one place this rule does not apply."
  }

}

variable "deny_actions" {
  description = "Actions denied on deny_secret_path_patterns. Every secretsmanager action, not a nominal list: this role's exposure is READ, so a Deny covering only the mutating set would leave the custody credential readable, and a list of verbs goes stale the next time AWS adds one. Ignored when deny_secret_path_patterns is empty."
  type        = list(string)
  default     = ["secretsmanager:*"]
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
