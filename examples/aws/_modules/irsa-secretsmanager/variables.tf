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

variable "deny_secret_path_patterns" {
  description = <<-EOT
    Secret name patterns this role is explicitly DENIED on, whatever else it is
    granted. Same no-trailing-"*" rule as secret_path_prefixes; the module appends
    one. Empty emits no Deny statement.

    AN EXPLICIT DENY IS NOT THE SAME AS A NARROWER ALLOW, and that is the whole
    reason this variable exists. Two roles on this estate need a broad Allow for
    reasons that are measured and not negotiable — tenant-manager because its own
    path builders emit three degenerate shapes that an environment-scoped prefix
    does not match, and External Secrets because it projects for every workload —
    and both of those broad Allows swallow the custody credential path as a side
    effect. A Deny is the only construct that carves a hole out of a wildcard, and
    in IAM it beats every Allow, including one attached later by somebody else.

    The pattern to use for the Dataprev custody path is
    "tenants/*/*/*/external/" (four segments before "external"). It matches
    tenants/{env}/{org}/{app}/external/... and NOT
    tenants/{env}/{tenantId}/{module}/kafka — including the case where a module is
    itself named "external", which a shorter pattern would catch by accident.

    ONE SHAPE IT DOES NOT COVER, IF YOU COPY THIS ELSEWHERE. lib-commons omits the
    environment segment entirely when the environment string is blank
    (commons/secretsmanager/external.go:92-95), producing
    tenants/{org}/{app}/external/... — three segments, which this pattern misses.
    On the consignado estate that path is unreachable, because ENV_NAME is a hard
    boot requirement for the gateway and the gateway's own Allow is scoped to
    tenants/production/ anyway, so the two are consistent. An estate where the
    environment is optional needs a second pattern.
  EOT

  type    = list(string)
  default = []

  validation {
    condition = alltrue([
      for pattern in var.deny_secret_path_patterns : !endswith(pattern, "*")
    ])
    error_message = "Do not write a trailing \"*\" in deny_secret_path_patterns: the module appends one."
  }
}

variable "deny_actions" {
  description = "Actions denied on deny_secret_path_patterns. Defaults to every mutating action: a Deny that only covered reads would leave the path writable, which is the property that matters for a custody trail. Narrow it to the read actions instead for a role that must not READ the path (External Secrets), or list both."
  type        = list(string)
  default = [
    "secretsmanager:CreateSecret",
    "secretsmanager:PutSecretValue",
    "secretsmanager:UpdateSecret",
    "secretsmanager:RestoreSecret",
    "secretsmanager:DeleteSecret",
    "secretsmanager:TagResource",
    "secretsmanager:UntagResource",
  ]

  validation {
    condition = alltrue([
      for action in var.deny_actions : startswith(action, "secretsmanager:")
    ])
    error_message = "Every entry in deny_actions must be a secretsmanager: action."
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

  # A Sid colliding with one of the module's own produces a policy document with a
  # duplicate Sid, which AWS rejects at APPLY time with a MalformedPolicyDocument
  # that names neither statement. Caught here instead.
  validation {
    condition = alltrue([
      for statement in var.extra_policy_statements :
      !contains(["ScopedSecretAccess", "DenyScopedSecretPaths", "ListSecretsAccountWide", "SecretEncryptionKey"], statement.sid)
    ])
    error_message = "The sids ScopedSecretAccess, DenyScopedSecretPaths, ListSecretsAccountWide and SecretEncryptionKey are reserved by this module. A duplicate Sid is rejected by AWS at apply time with an error that names neither statement."
  }
}

variable "additional_policy_names" {
  description = <<-EOT
    Names of EXISTING customer-managed IAM policies to attach to this role, in
    addition to the one this module writes. Names, not ARNs: the module resolves
    the account and partition, so nothing here carries an account id.

    THIS IS HOW A SERVICE ENDS UP WITH ONE ROLE INSTEAD OF TWO. A Kubernetes
    ServiceAccount carries exactly one eks.amazonaws.com/role-arn annotation, so a
    service needing both the vault and an S3 bucket cannot have a role per concern
    — one of the two grants would be unreachable, and the symptom is an
    AccessDenied on whichever path nobody tested. _modules/s3-bucket already emits
    its grant as a standalone attachable policy named
    "{product}-{env}-{logical}-s3-access" for exactly this.

    THE POLICY MUST ALREADY EXIST. An attachment to a name that is not there fails
    with NoSuchEntity, which is loud and fixable; it does not fail silently. Apply
    the s3 root first — see its README.
  EOT

  type    = list(string)
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
