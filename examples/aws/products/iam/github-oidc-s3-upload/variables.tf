variable "region" {
  description = "AWS region the role is created in. IAM is global, but the region selects the endpoint and appears in the ARNs of everything the attached policy scopes to. S3 bucket ARNs carry no region, so this value reaches only the provider and the tags."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", var.region))
    error_message = "The region must be a valid AWS region identifier, e.g. sa-east-1."
  }
}

variable "environment" {
  description = "Deployment environment this apply belongs to. One of dev, stg or prd; it feeds tags and the state key's backend config. ONE role serves EVERY release channel, so this root is applied only as \"prd\" — the role is a property of the account that owns the bucket, not of a stack. The channel (development/staging/production) is a FOLDER inside the bucket, chosen by the release pipeline from the tag, never by a second apply."
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

variable "github_repository" {
  description = <<-EOT
    The GitHub repository whose release pipeline may assume this role, as
    `owner/repo` — e.g. `LerianStudio/br-consignado-gw`.

    It becomes the `:sub` condition of the trust policy, as
    `repo:{owner}/{repo}:ref:refs/tags/*`, and it is the whole boundary: every
    GitHub Actions token in existence is signed by the same issuer, so without
    `:sub` any workflow on GitHub could assume this role.

    The repository segment ALSO names the object prefixes the policy grants,
    because go-release publishes under a prefix that starts with the repository
    name. One input, so the identity that uploads and the path it may write to
    cannot drift apart.
  EOT

  type = string

  # ONE regex, not a shape check plus a length check. The length of the repo
  # segment is `split("/", ...)[1]`, and on a value with no "/" that index is an
  # EVALUATION error, not a validation failure: terraform aborts with "Invalid
  # index" pointing at this file instead of refusing the input with the message
  # below. The 24-character cap therefore lives inside the pattern — it is
  # _modules/naming's limit on the product label, which this value becomes.
  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[a-z0-9]([a-z0-9-]{0,22}[a-z0-9])?$", var.github_repository))
    error_message = "github_repository must be owner/repo, with a repo segment of at most 24 lowercase alphanumerics and interior hyphens. That segment is used twice with no escape hatch: it is interpolated into the S3 object prefixes the policy grants, and it is passed to _modules/naming as the product label, which caps it at 24 characters and rejects anything but that charset."
  }
}

variable "role_name" {
  description = "Exact name of the role. Explicit rather than derived from module.naming because this string is copied verbatim into the release workflow of ANOTHER repository, as the `aws_role_arn` of an `s3_uploads` entry: a rename here breaks that workflow, and an explicit name makes the coupling visible on both sides."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9+=,.@_-]{1,64}$", var.role_name))
    error_message = "role_name must be 1-64 characters from the IAM name charset [A-Za-z0-9+=,.@_-]."
  }
}

################################################################################
# Reach — what the role may do once assumed
################################################################################

variable "migrations_bucket_name" {
  description = <<-EOT
    Name of the bucket the release pipeline uploads migrations to — the bucket
    the tenant manager reads them back from. It lives in THIS account; that is
    what makes a bucket policy unnecessary.

    A name, not an ARN: main.tf builds
    `arn:{partition}:s3:::{name}/{channel}/{repo}/*` from it.
  EOT

  type = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.migrations_bucket_name))
    error_message = "migrations_bucket_name must be a bucket NAME (3-63 characters, lowercase alphanumerics, dots and hyphens) — not an ARN and not a URL. An ARN pasted here becomes an ARN inside an ARN and grants nothing, silently."
  }
}
