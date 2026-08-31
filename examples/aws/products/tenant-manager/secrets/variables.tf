variable "region" {
  description = "AWS region the role is created in. IAM is global, but the secret ARNs the policy scopes to are regional."
  type        = string
  default     = "us-east-1"
}

variable "product" {
  description = "Pinned to \"tenant-manager\": the derived role name is the cross-stack discovery contract."
  type        = string
  default     = "tenant-manager"

  validation {
    condition     = var.product == "tenant-manager"
    error_message = "This stack is tenant-manager. A second product gets its own directory under examples/aws/products."
  }
}

variable "environment" {
  description = "Deployment environment. One of dev, stg or prd. NAMES THE IAM OBJECTS ONLY — the environment segment inside the vault paths is the application's ENV_NAME (\"production\" here) and goes in secret_path_prefixes."
  type        = string
}

variable "component" {
  description = "Component suffix for the role name, producing tenant-manager-{env}-{component}-irsa."
  type        = string
  default     = "secrets"
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
  description = "Kubernetes service account the role is pinned to, \"namespace:name\"."
  type        = string
  default     = "platform:tenant-manager"
}

variable "secret_path_prefixes" {
  description = <<-EOT
    Vault prefixes tenant-manager may act on. NO TRAILING "*" — the module appends
    one.

    THIS ONE IS SCOPED TO THE TWO ROOTS ("tenants/" and "clusters/") RATHER THAN TO
    AN ENVIRONMENT, ON PURPOSE, and that is a deliberate widening rather than
    laziness. Three measured shapes make a tighter scope wrong:

      1. clusters/production/{dbType}/{service}/shared/admin  in production, but
         clusters/{env}/{dbType}/shared/admin                 everywhere else.
      2. Several provisioning handlers pass the environment as the EMPTY STRING,
         producing clusters/{dbType}/{service}/... with no env segment at all.
      3. One path writes tenants/{tenantID}/{stackName}/admin with the UUID dashes
         intact, unlike every other builder, and with no env segment.

    A prefix of "tenants/production/" matches none of 2 or 3, and the failure mode
    is a 404 on admin credential lookup mid-provisioning rather than a plan error.

    NARROW THIS ONLY AFTER the shapes above are fixed upstream in tenant-manager.
  EOT

  type    = list(string)
  default = []
}

variable "read_actions" {
  description = "Resource-scoped read actions. DescribeSecret is a separate IAM action from GetSecretValue and tenant-manager calls it on the provisioning path to decide whether to create or update."
  type        = list(string)
  default = [
    "secretsmanager:GetSecretValue",
    "secretsmanager:DescribeSecret",
  ]
}

variable "write_actions" {
  description = <<-EOT
    Resource-scoped write actions. tenant-manager UPSERTS, which the gateway does
    not, so this list is genuinely wider than the gateway's and the difference is
    not an oversight:

      CreateSecret     first write
      PutSecretValue   subsequent writes of the same secret
      RestoreSecret    un-deletes a secret inside its 7 day recovery window, which
                       is a live path on re-provision
      DeleteSecret     both soft-delete and ForceDeleteWithoutRecovery

    TagResource is absent because it is never called.
  EOT

  type = list(string)
  default = [
    "secretsmanager:CreateSecret",
    "secretsmanager:PutSecretValue",
    "secretsmanager:RestoreSecret",
    "secretsmanager:DeleteSecret",
  ]
}

variable "deny_secret_path_patterns" {
  description = <<-EOT
    Paths this role may NOT write, whatever the Allow says.

    THE CUSTODY PATH GOES HERE, AND IT IS NOT OPTIONAL. The Allow above has to
    reach all of tenants/ — three measured path shapes make anything narrower a 404
    mid-provisioning — and tenants/ swallows
    tenants/{env}/{org}/{app}/external/{target}/credentials/versions/{uuid}, which
    is a tenant's Dataprev credential.

    The gateway pays for that credential to be IMMUTABLE: a variable validation
    refuses it PutSecretValue, so a rotation writes a new version path and the
    audit trail cannot be rewritten. That property is worth nothing if the control
    plane next door holds PutSecretValue and DeleteSecret over the same ARNs — a
    compromised or merely buggy tenant-manager would overwrite or force-delete a
    custody version without ever touching the gateway's audited API.

    tenant-manager never writes under {app}/external/. It writes {module}/kafka,
    m2m/... and admin. So the Deny costs it nothing and makes the gateway's
    immutability an invariant of the estate rather than of one role.
  EOT

  type    = list(string)
  default = []
}

variable "deny_actions" {
  description = "Actions denied on deny_secret_path_patterns. The mutating set: a Deny that covered only reads would leave the custody credential writable, which is the property that matters. Reads are left alone — tenant-manager has no reason to read a custody credential either, but denying the read would be a behaviour change without a measured caller behind it."
  type        = list(string)
  default = [
    "secretsmanager:CreateSecret",
    "secretsmanager:PutSecretValue",
    "secretsmanager:UpdateSecret",
    "secretsmanager:RestoreSecret",
    "secretsmanager:DeleteSecret",
  ]
}

variable "allow_list_secrets" {
  description = "Grant account-wide secretsmanager:ListSecrets. TRUE: the readiness probe lists unscoped. AWS does not evaluate ListSecrets against a resource, so this necessarily carries Resource \"*\"."
  type        = bool
  default     = true
}

variable "kms_key_arns" {
  description = "Customer managed keys the role may use for Decrypt/GenerateDataKey. Needed the day a CMK backs the vault; CreateSecret fails on the encrypt without it."
  type        = list(string)
  default     = []
}

variable "additional_policy_names" {
  description = "Existing customer-managed policies attached to this role by name. THIS IS THE ONE-ROLE DECISION: tenant-manager needs the vault AND its two S3 buckets, and a ServiceAccount carries exactly one role-arn annotation, so the bucket grant is attached here rather than living on a second role nobody can annotate. The name comes from products/tenant-manager/s3, which must be applied first — see the runbook."
  type        = list(string)
  default     = []
}

variable "extra_policy_statements" {
  description = <<-EOT
    Non-Secrets-Manager grants attached to the SAME role, because tenant-manager
    provisions cloud resources with the same identity it reads secrets with.

    Measured clients (internal/bootstrap/wire_infra_aws.go): CloudFormation, RDS,
    DocDB, EC2 (describe only) and S3. NOT MSK — Kafka users and ACLs go over the
    Kafka wire protocol, so that is a security group concern, not IAM.

    Left EMPTY BY DEFAULT so that the vault half of this role can be applied on its
    own, before anyone has decided how much provisioning power the control plane
    should hold in this account. Every entry is a decision; the tfvars is where
    those decisions are written down and reviewed.

    Note that CloudFormation executes under whatever role it is given, so a
    CreateStack grant is effectively a grant of everything those templates create,
    plus iam:PassRole if an execution role is used. That is a product decision, not
    a Terraform one.
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
