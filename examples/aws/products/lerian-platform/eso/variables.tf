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
  description = <<-EOT
    Vault prefixes ESO may read. NO TRAILING "*" — the module appends one.

    THERE ARE TWO UNRELATED NAMING FAMILIES IN THIS VAULT AND A LIST THAT COVERS
    ONLY ONE OF THEM PRODUCES AN OPERATOR THAT CANNOT READ A SINGLE DATABASE
    PASSWORD:

      application secrets   tenants/{env}/...    written by tenant-manager and by
                            clusters/{env}/...   the gateway, at runtime
      installation secrets  installation/{env}/...  written BY HAND by the operator;
                                                    the streaming-hub KEK is the only
                                                    one today
      datastore secrets     {product}-{env}-postgres/password
                            {product}-{env}-valkey/auth-token
                            {product}-{env}-docdb/password
                            AmazonMSK_{name}      written by THIS repository's
                                                  datastore modules, at apply time

    The third family is every credential Terraform itself generates
    (_modules/postgres-rds/main.tf:255, valkey-elasticache/main.tf:226,
    mongodb-documentdb/main.tf:177, streaming-msk/main.tf:88-92). None of them
    starts with tenants/ or clusters/.

    DEFAULT IS EMPTY, DELIBERATELY. The module refuses to build a role whose read
    actions have no resource, so an unset list fails the plan instead of producing
    an operator that syncs nothing. The list belongs in the tfvars, where adding a
    product is a reviewable line.
  EOT

  type    = list(string)
  default = []
}

variable "read_actions" {
  description = "Resource-scoped read actions. GetSecretValue projects the value; DescribeSecret is what ESO uses to detect a changed version and re-sync. BatchGetSecretValue is not included — no Lerian consumer uses it, and ESO falls back to per-secret reads."
  type        = list(string)
  default = [
    "secretsmanager:GetSecretValue",
    "secretsmanager:DescribeSecret",
  ]
}

variable "deny_secret_path_patterns" {
  description = <<-EOT
    Paths ESO may NOT touch, whatever the Allow says. A Deny beats every Allow in
    IAM, including one attached later.

    THE DATAPREV CUSTODY PATH BELONGS HERE. ESO's Allow has to be broad — it
    projects for every workload — and broad over tenants/ swallows
    tenants/{env}/{org}/{app}/external/{target}/credentials/versions/{uuid}, which
    is a tenant's Dataprev credential. Anyone able to create an ExternalSecret in
    any namespace could then project that credential into a Secret they read. The
    gateway reads its own custody store with its OWN role and does not need ESO for
    it, so denying the path costs nothing and closes an exfiltration route that no
    amount of write-side hardening would have caught.
  EOT

  type    = list(string)
  default = []
}

variable "deny_actions" {
  description = "Actions denied on deny_secret_path_patterns. For ESO the denial that matters is the READ — it has no write actions to deny. GetSecretValue alone would leave DescribeSecret and BatchGetSecretValue open, and BatchGetSecretValue returns values."
  type        = list(string)
  default = [
    "secretsmanager:GetSecretValue",
    "secretsmanager:BatchGetSecretValue",
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

    THIS IS NOT THE ONLY CAUSE OF SecretSyncedError, and it is not the first one to
    check. A path outside secret_path_prefixes produces the same symptom and is far
    more common — see that variable's two naming families.
  EOT

  type    = list(string)
  default = []
}
