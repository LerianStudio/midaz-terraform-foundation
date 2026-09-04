variable "region" {
  description = "AWS region the role and the OIDC provider copy are created in. IAM is global, but the region selects the endpoint and appears in the ARNs of everything the attached policies scope to, so it must be the region of the resources this role reaches."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", var.region))
    error_message = "The region must be a valid AWS region identifier, e.g. sa-east-1."
  }
}

variable "environment" {
  description = "Deployment environment this apply belongs to. One of dev, stg or prd; it feeds tags and the state key's backend config. ONE role serves BOTH application stacks, so this root is applied only as \"prd\" — the role is a property of the account, not of a stack, and a second copy in \"stg\" would be a second identity with the same trust and the same reach."
  type        = string
}

variable "extra_tags" {
  description = "Additional tags merged on top of the standard Lerian tag set."
  type        = map(string)
  default     = {}
}

################################################################################
# Trust — who may assume this role
################################################################################

variable "oidc_issuer_url" {
  description = <<-EOT
    OIDC issuer URL of the EKS cluster in the OTHER account — the control plane's
    `lerian-dev-eks`. `aws eks describe-cluster --name lerian-dev-eks --query
    cluster.identity.oidc.issuer`, or `terraform output` of that cluster's root.

    Registering it here creates a copy of that issuer as an identity provider in
    THIS account. Without the copy, a token minted by the control-plane cluster
    is not a principal this account recognises and no trust policy can name it.
  EOT

  type = string

  validation {
    condition     = startswith(var.oidc_issuer_url, "https://oidc.eks.")
    error_message = "oidc_issuer_url must be an EKS issuer URL, starting with https://oidc.eks. — e.g. https://oidc.eks.sa-east-1.amazonaws.com/id/EXAMPLE. The unresolved placeholder this tfvars ships with is caught here as well as by lerian-infra."
  }
}

variable "oidc_thumbprint" {
  description = "SHA-1 thumbprint of the CA that signs the EKS OIDC endpoint. It is the AWS-managed root, constant across clusters and regions, which is why it is a default rather than an input to look up: the same value the SaaS estate pins in environments/production/platform/iam/tenant_manager_cross_account. Overriding it is only correct if AWS rotates that root."
  type        = string
  default     = "9e99a48a9960b14926bb7f3b02e22da2b0ab7280"

  validation {
    condition     = can(regex("^[0-9a-f]{40}$", var.oidc_thumbprint))
    error_message = "oidc_thumbprint must be 40 lowercase hex characters (a SHA-1 fingerprint with no colons)."
  }
}

variable "sa_subject" {
  description = <<-EOT
    Kubernetes ServiceAccount allowed to assume this role, as `namespace:name` —
    the same form `_modules/irsa-secretsmanager` takes. For the control plane's
    tenant-manager: `platform:tenant-manager`.

    It becomes the `:sub` condition of the trust policy, so it is the whole
    boundary: any ServiceAccount in that cluster whose namespace and name match
    can assume the role, and no other can. A typo does not fail the apply — the
    pod comes up and every AWS call returns AccessDenied.
  EOT

  type = string

  validation {
    condition     = can(regex("^[a-z0-9-]+:[a-z0-9.-]+$", var.sa_subject))
    error_message = "sa_subject must be namespace:name, e.g. platform:tenant-manager."
  }
}

variable "role_name" {
  description = "Exact name of the role. Explicit rather than derived from module.naming because this string is copied verbatim into the ServiceAccount's eks.amazonaws.com/role-arn annotation in another repository, in another account: a rename here silently breaks the annotation over there, and an explicit name makes the coupling visible on both sides."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9+=,.@_-]{1,64}$", var.role_name))
    error_message = "role_name must be 1-64 characters from the IAM name charset [A-Za-z0-9+=,.@_-]."
  }
}

################################################################################
# Reach — what the role may do once assumed
################################################################################

variable "policy_json" {
  description = <<-EOT
    The role's inline policy, as a JSON document. Written out in the tfvars, not
    assembled from knobs, because it is a TRANSCRIPTION: the same grants the
    in-account role `_modules/irsa-secretsmanager` emits today from
    products/tenant-manager/secrets, which is the identity this role replaces
    when the service moves to the control-plane account. A knob-built policy
    would look tidier and would drift from the thing it is supposed to equal.

    IT DOES NOT CARRY THE CUSTODY DENY, and must not have to: main.tf appends
    that statement to whatever this document holds, on every apply. Transcribe
    the Allow statements here and nothing else — a Deny written here as well is
    accepted (IAM takes the union of denies), it is simply redundant.
  EOT

  type = string

  validation {
    condition     = can(jsondecode(var.policy_json))
    error_message = "policy_json must be a valid JSON document."
  }

  validation {
    condition     = try(jsondecode(var.policy_json).Version, "") == "2012-10-17"
    error_message = "policy_json must declare \"Version\": \"2012-10-17\". IAM accepts 2008-10-17 and then silently ignores policy variables and several condition operators."
  }
}

variable "additional_policy_names" {
  description = <<-EOT
    Names (not ARNs) of managed policies in THIS account to attach on top of
    policy_json. They are resolved to
    arn:{partition}:iam::{this account}:policy/{name}.

    Measured, and not optional for the control plane: products/tenant-manager/s3
    runs with irsa_enabled = false and emits
    `tenant-manager-prd-migrations-s3-access` and
    `tenant-manager-prd-casdoor-templates-s3-access` for a role to borrow. Without
    them the Casdoor templates are unreachable and tenant onboarding fails at the
    template fetch. A ServiceAccount carries exactly one role-arn annotation, so
    borrowing is how one role holds both concerns.

    APPLY products/tenant-manager/s3 FIRST. Attaching a policy that does not exist
    fails with NoSuchEntity — loud, not silent.
  EOT

  type    = list(string)
  default = []
}
