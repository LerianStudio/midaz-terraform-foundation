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
    condition     = can(regex("^https://oidc\\.eks\\.[a-z0-9-]+\\.amazonaws\\.com(\\.cn)?/id/[0-9A-F]{32}$", var.oidc_issuer_url))
    error_message = "oidc_issuer_url must be a COMPLETE EKS issuer URL — https://oidc.eks.{region}.amazonaws.com/id/{32 uppercase hex}, e.g. https://oidc.eks.sa-east-1.amazonaws.com/id/0123456789ABCDEF0123456789ABCDEF; the .com.cn host is accepted for the China partitions, and aws-us-gov regions need no special case. The full hostname and the /id/ path are both required because this value is not merely recorded: it is registered as an identity provider in THIS account, and a host anyone can register under the prefix https://oidc.eks. — oidc.eks.attacker.example — would become a trusted issuer whose tokens the trust policy accepts. The unresolved placeholder this tfvars ships with is caught here as well as by lerian-infra."
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
    redundant, and accepted (IAM takes the union of denies) only under a Sid
    other than DenyDataprevCustodyPaths. Reusing that Sid is a
    MalformedPolicyDocument and fails the apply.
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

    EXACTLY TWO, and which two is not a preference. products/tenant-manager/s3
    runs with irsa_enabled = false and emits no role of its own: it emits
    `tenant-manager-{env}-migrations-s3-access` and
    `tenant-manager-{env}-casdoor-templates-s3-access` for a role to borrow.
    Without the second one the Casdoor templates are unreachable and tenant
    onboarding fails at the template fetch — a working control plane needs both,
    so the validation below requires one of each rather than accepting whatever
    list somebody wrote. A ServiceAccount carries exactly one role-arn
    annotation, which is why borrowing is how one role holds both concerns.

    The ENVIRONMENT SEGMENT is free. That sibling root derives the name from its
    own environment, and freezing "prd" here would make this root refuse a
    correct list in any other one. What is pinned is the pair of suffixes, which
    is that root's contract inside THIS repository — coupling to a sibling, not
    to a consumer.

    APPLY products/tenant-manager/s3 FIRST. Attaching a policy that does not exist
    fails with NoSuchEntity — loud, not silent.

    NO DEFAULT, deliberately, and now nothing to default TO: a default of []
    made "the control plane needs both S3 policies" and "somebody forgot to say"
    the same tfvars, and the second one applies cleanly and loses the templates.
  EOT

  type = list(string)

  validation {
    condition = alltrue([
      for name in var.additional_policy_names :
      can(regex("^[A-Za-z0-9+=,.@_-]{1,128}$", name))
    ])
    error_message = "Every entry must be a managed policy NAME of 1-128 characters from the IAM name charset [A-Za-z0-9+=,.@_-] — not an ARN and not a path. main.tf builds arn:{partition}:iam::{this account}:policy/{name} from each entry, so an ARN pasted here becomes an ARN inside an ARN and fails at apply with NoSuchEntity, naming a policy nobody can find."
  }

  validation {
    condition = (
      length(var.additional_policy_names) == 2 &&
      length([
        for name in var.additional_policy_names : name
        if can(regex("^tenant-manager-[a-z0-9-]+-migrations-s3-access$", name))
      ]) == 1 &&
      length([
        for name in var.additional_policy_names : name
        if can(regex("^tenant-manager-[a-z0-9-]+-casdoor-templates-s3-access$", name))
      ]) == 1
    )
    error_message = "additional_policy_names must hold EXACTLY the two policies products/tenant-manager/s3 emits — one name ending in -migrations-s3-access and one ending in -casdoor-templates-s3-access, both prefixed tenant-manager- (e.g. tenant-manager-prd-migrations-s3-access and tenant-manager-prd-casdoor-templates-s3-access). BOTH are mandatory for the control plane: without the casdoor-templates policy the templates are unreachable and tenant onboarding fails at the template fetch, and the migrations policy is what lets the tenant manager run a new tenant's schema. The environment segment is free on purpose — that root names its policies after its own environment — but the two suffixes are its contract, one of each, nothing else in the list."
  }
}
