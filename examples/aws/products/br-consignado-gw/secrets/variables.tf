variable "region" {
  description = "AWS region the role is created in. IAM is global, but the secret ARNs the policy scopes to are regional, so this must be the region the vault lives in."
  type        = string
  default     = "us-east-1"
}

variable "product" {
  description = "Pinned to \"br-consignado-gw\": the derived role name is the cross-stack discovery contract, and a different value here silently produces a role the gateway's ServiceAccount annotation does not point at."
  type        = string
  default     = "br-consignado-gw"

  validation {
    condition     = var.product == "br-consignado-gw"
    error_message = "This stack is br-consignado-gw. A second product gets its own directory under examples/aws/products."
  }
}

variable "environment" {
  description = "Deployment environment. One of dev, stg or prd. NAMES THE IAM OBJECTS ONLY — the environment segment inside the vault paths is the application's ENV_NAME and goes in secret_path_prefixes."
  type        = string
}

variable "component" {
  description = "Component suffix for the role name, producing br-consignado-gw-{env}-{component}-irsa."
  type        = string
  default     = "secrets"
}

variable "extra_tags" {
  description = "Additional tags merged on top of the standard Lerian tag set."
  type        = map(string)
  default     = {}
}

variable "eks_cluster_name" {
  description = "EKS cluster whose OIDC provider backs the role. Leave empty (the default) to DERIVE \"lerian-{environment}-eks\" — the cluster belongs to infra-base and carries the \"lerian\" product label, not this product's."
  type        = string
  default     = ""
}

variable "oidc_provider_arn" {
  description = "Escape hatch overriding the OIDC provider lookup. Empty (the default) derives it from the cluster name, which is how every other cross-stack reference in this repository works. A hand-copied ARN rots silently when the cluster is replaced."
  type        = string
  default     = ""
}

variable "service_account" {
  description = "Kubernetes service account the role is pinned to, \"namespace:name\". Must match the ServiceAccount the gateway chart actually creates: the :sub condition admits nothing else, in any namespace."
  type        = string
  default     = "consignado:br-consignado-gw"
}

variable "secret_path_prefixes" {
  description = <<-EOT
    Vault prefixes the gateway may act on. NO TRAILING "*" — the module appends it.

    THE SEGMENT AFTER "tenants/" IS THE APPLICATION'S ENV_NAME. On this estate it
    is "production" in BOTH accounts, because a custody reference is re-parsed on
    read and demands exact scope equality: rename the environment later and every
    credential already stored becomes unreadable. It is "production" from the first
    write, forever.

    One caveat worth knowing before an AccessDenied at 2am: lib-commons omits the
    env segment entirely when the environment string is blank
    (commons/secretsmanager/external.go:92-95), producing tenants/{orgID}/... A
    prefix of "tenants/production/" does not match that. Cover it deliberately if
    a blank ENV_NAME is reachable; on this estate ENV_NAME is a hard boot
    requirement, so it is not.
  EOT

  type    = list(string)
  default = []
}

variable "read_actions" {
  description = "Resource-scoped read actions. GetSecretValue reads the custody credential and the M2M credential; DescribeSecret is used by the writer to check whether a staged version already exists before creating it."
  type        = list(string)
  default = [
    "secretsmanager:GetSecretValue",
    "secretsmanager:DescribeSecret",
  ]
}

variable "write_actions" {
  description = "Resource-scoped write actions. CreateSecret stages a new immutable credential version; DeleteSecret rolls a failed staging back. PutSecretValue IS DELIBERATELY ABSENT and must stay absent — it would make an already-written custody version rewritable, which is the one property the audit trail depends on."
  type        = list(string)
  default = [
    "secretsmanager:CreateSecret",
    "secretsmanager:DeleteSecret",
  ]

  validation {
    condition     = !contains(var.write_actions, "secretsmanager:PutSecretValue")
    error_message = "secretsmanager:PutSecretValue must not be granted to the gateway. A custody credential version is immutable by design: rotation writes a NEW version path. Granting overwrite makes the money-path audit trail rewritable."
  }
}

variable "allow_list_secrets" {
  description = "Grant account-wide secretsmanager:ListSecrets. FALSE, and it should stay false: the gateway reads by exact reference and enumerates nothing, and ListSecrets cannot be resource-scoped."
  type        = bool
  default     = false
}

variable "kms_key_arns" {
  description = "Customer managed keys the role may use. Empty is correct while the vault uses the AWS-managed aws/secretsmanager key — the gateway makes no explicit KMS call anywhere (no kms SDK import, no SSEKMSKeyId). Populate it the day a CMK backs these secrets, or CreateSecret starts failing on the encrypt."
  type        = list(string)
  default     = []
}
