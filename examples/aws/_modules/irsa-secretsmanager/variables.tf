################################################################################
# Contract variables
#
# NOTE: this module has no `mode`. See README.md — an IAM role is not a datastore
# and there is no shared tier to resolve.
################################################################################

variable "product" {
  description = "Lerian product this role belongs to (e.g. br-consignado-gw, streaming-hub, tenant-manager). Names the role and the policy through the naming module."
  type        = string
}

variable "environment" {
  description = "Deployment environment. One of dev, stg or prd. THIS IS THE REPOSITORY's environment vocabulary and it names the IAM objects. It is NOT the environment segment inside the secret paths — that is the application's ENV_NAME (\"production\" on the consignado estate) and it goes in var.secret_path_prefixes."
  type        = string

  validation {
    condition     = contains(["dev", "stg", "prd"], var.environment)
    error_message = "The environment must be one of: dev, stg, prd."
  }
}

variable "component" {
  description = "Component suffix distinguishing this role from a sibling role of the same product. Defaults to \"secrets\", producing {product}-{environment}-secrets-irsa."
  type        = string
  default     = "secrets"
}

################################################################################
# IRSA binding
################################################################################

variable "oidc_provider_arn" {
  description = "ARN of the EKS cluster IAM OIDC provider, exported by infra-base/eks as oidc_provider_arn. Required: unlike _modules/s3-bucket, this module has nothing useful to emit without a role, because a policy nobody can assume grants nobody anything."
  type        = string

  validation {
    condition     = can(regex("^arn:[^:]+:iam::[0-9]{12}:oidc-provider/", var.oidc_provider_arn))
    error_message = "The oidc_provider_arn must be a full IAM OIDC provider ARN, e.g. arn:aws:iam::123456789012:oidc-provider/oidc.eks.sa-east-1.amazonaws.com/id/ABC123."
  }
}

variable "service_account" {
  description = "Kubernetes service account allowed to assume the role, in \"namespace:name\" form — the same notation infra-base/eks/iam.tf and _modules/s3-bucket use. The :sub condition is pinned to exactly this value, so a pod in another namespace, or under another service account name, cannot assume the role even inside the same cluster."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?:[a-z0-9]([a-z0-9.-]*[a-z0-9])?$", var.service_account))
    error_message = "The service_account must be in \"namespace:name\" form, e.g. \"consignado:br-consignado-gw\"."
  }
}

################################################################################
# Grants
################################################################################

variable "secret_path_prefixes" {
  description = <<-EOT
    Secret NAME prefixes this role may act on, e.g. ["tenants/production/"]. Each
    becomes one resource ARN in the policy.

    A trailing "*" is appended by the module and MUST NOT be written here: Secrets
    Manager suffixes every ARN with six random characters, so even an exact secret
    name needs the wildcard, and a caller that adds their own produces "**".

    THE SEGMENT AFTER "tenants/" OR "clusters/" IS THE APPLICATION'S ENV_NAME, not
    this repository's environment. On the consignado estate that is "production",
    while var.environment is "prd". Writing "prd" here yields a policy that matches
    nothing.
  EOT

  type    = list(string)
  default = []

  validation {
    condition = alltrue([
      for prefix in var.secret_path_prefixes : !endswith(prefix, "*")
    ])
    error_message = "Do not write a trailing \"*\" in secret_path_prefixes: the module appends one, and two produce a pattern that matches nothing useful."
  }

  validation {
    condition = alltrue([
      for prefix in var.secret_path_prefixes : trimspace(prefix) != ""
    ])
    error_message = "An empty or blank prefix would scope the policy to every secret in the account. Grant that deliberately with the literal \"/\" if it is really what you mean."
  }
}

variable "read_actions" {
  description = "Resource-scoped read actions granted on secret_path_prefixes. The default is the minimum a consumer needs: fetch the value, and check whether the secret exists. DescribeSecret is separate from GetSecretValue in IAM and several Lerian services call it on the provisioning path."
  type        = list(string)
  default = [
    "secretsmanager:GetSecretValue",
    "secretsmanager:DescribeSecret",
  ]
}

variable "write_actions" {
  description = <<-EOT
    Resource-scoped write actions granted on secret_path_prefixes. Empty by
    default: most consumers only read.

    Two Lerian services write, and they write DIFFERENTLY:

      tenant-manager      CreateSecret, PutSecretValue, RestoreSecret, DeleteSecret
                          — it upserts, and RestoreSecret exists to un-delete a
                          secret scheduled for deletion.
      br-consignado-gw    CreateSecret, DeleteSecret — and NEVER PutSecretValue.
                          A custody credential version is immutable by design: a
                          rotation is a new secret at a new version path, never an
                          overwrite of the old one. Granting PutSecretValue would
                          make the money-path audit trail rewritable.

    So this is a list, not a boolean.
  EOT

  type    = list(string)
  default = []

  validation {
    condition = alltrue([
      for action in var.write_actions : startswith(action, "secretsmanager:")
    ])
    error_message = "Every entry in write_actions must be a secretsmanager: action."
  }
}

variable "allow_list_secrets" {
  description = <<-EOT
    Grant secretsmanager:ListSecrets. SEPARATE FROM EVERYTHING ELSE BECAUSE IT
    CANNOT BE SCOPED: AWS evaluates ListSecrets against the account, so the
    statement must carry Resource "*" and the caller learns every secret NAME in
    the account (never a value).

    Two consumers genuinely need it and neither can be narrowed:

      streaming-hub    builds its multi-tenant roster by listing
                       tenants/{env}/*/{module}/kafka. An empty listing makes it
                       REFUSE TO BOOT, so a missing grant looks like a crashloop,
                       not a permissions error.
      tenant-manager   readiness probe.

    Leave false for anything that only reads a known path.
  EOT

  type    = bool
  default = false
}

variable "kms_key_arns" {
  description = "Customer managed keys this role may use for kms:Decrypt and kms:GenerateDataKey. Needed when a secret is encrypted with a CMK rather than the AWS-managed aws/secretsmanager key — which is the case for every MSK SCRAM secret, because AWS refuses a managed key there — and when the role calls CreateSecret on an account with a CMK default. Empty emits no KMS statement."
  type        = list(string)
  default     = []
}

variable "extra_policy_statements" {
  description = <<-EOT
    Additional non-secretsmanager statements attached to the SAME role, for a
    service whose IRSA identity needs more than the vault.

    tenant-manager is the only current case and it is a big one: it drives
    CloudFormation, RDS, DocumentDB, EC2 describe and S3 with the same identity.
    Those grants belong in its own root's tfvars where they can be read and argued
    with, not hidden in a default here.

    Each entry is {sid, actions, resources}, optionally with condition.
  EOT

  type = list(object({
    sid       = string
    actions   = list(string)
    resources = list(string)
    condition = optional(object({
      test     = string
      variable = string
      values   = list(string)
    }))
  }))
  default = []
}

################################################################################
# Tagging
################################################################################

variable "extra_tags" {
  description = "Additional tags merged on top of the standard Lerian tag set."
  type        = map(string)
  default     = {}
}
