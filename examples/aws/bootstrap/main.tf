################################################################################
# Terraform state bootstrap — one S3 bucket + one DynamoDB lock table per env
#
# This is the chicken-and-egg stack: it CREATES the S3 backend that every other
# stack in this repository uses. It therefore cannot itself use that backend, so
# there is deliberately NO backend.tf here and the state of this stack is LOCAL.
#
# ---------------------------------------------------------------------------
# 1. Where the state of THIS stack lives
# ---------------------------------------------------------------------------
# Local, on the machine that ran the apply. Pick one of:
#
#   a) Commit it to the client's PRIVATE infrastructure repository. The state of
#      this stack holds no secrets — a bucket name, a table name, an account id —
#      but it is not public information either, so a private repo only.
#
#   b) Migrate it into the bucket it just created, which is safe once the bucket
#      exists:
#
#        terraform init -migrate-state \
#          -backend-config=../backend/dev.hcl \
#          -backend-config="key=aws/bootstrap/terraform.tfstate"
#
#      After migrating, a future teardown of the bucket destroys the state that
#      describes the bucket. That is recoverable (terraform import) but annoying,
#      which is why (a) is the recommended default.
#
# Losing this state does NOT lose the bucket or the table. It only means a later
# `terraform import` is required before Terraform will manage them again.
#
# ---------------------------------------------------------------------------
# 2. Running it for more than one environment (READ THIS)
# ---------------------------------------------------------------------------
# A single local state file cannot hold dev, stg and prd: the second apply would
# see the first environment's resources as "must be replaced" and rewrite the
# state, orphaning the first environment's bucket and table.
#
# DECISION: this stack uses local Terraform WORKSPACES, one per environment.
#
#   terraform workspace new dev && terraform apply -var-file=envs/dev.tfvars
#   terraform workspace new stg && terraform apply -var-file=envs/stg.tfvars
#
# Workspaces win over `-state=dev.tfstate` because the selection is sticky: it
# is stored in .terraform/environment and applies to every subsequent command
# (plan, apply, output, destroy, state). A `-state=` flag has to be repeated on
# every single command and the one time it is forgotten, Terraform silently
# writes to terraform.tfstate and the environments collide — exactly the failure
# this segregation exists to prevent. Workspace state lands under
# terraform.tfstate.d/<workspace>/terraform.tfstate.
#
# The aws_s3_bucket precondition below enforces workspace == environment, so a
# `terraform apply -var-file=envs/prd.tfvars` inside the dev workspace fails at
# plan time instead of clobbering dev. Workspace "default" is exempt so the
# `-state=` approach remains possible for anyone who prefers it.
#
# ---------------------------------------------------------------------------
# 3. prevent_destroy — how to tear this down on purpose
# ---------------------------------------------------------------------------
# The bucket and the lock table carry `prevent_destroy = true`. State is the most
# destructive thing in this repository to lose: without it Terraform no longer
# knows which resources it owns, and every subsequent apply tries to recreate
# live infrastructure. Convenience of teardown does not outrank that, and this
# guard is fixed rather than variable-driven because Terraform does not allow
# expressions inside a lifecycle block.
#
# Consequence: `terraform destroy` on this stack FAILS while the guard is in
# place. That is intended. To tear down a validation environment, either:
#
#   a) Detach the resources from Terraform and delete them with the AWS CLI
#      (no source edit, therefore no risk of the edit being committed):
#
#        terraform state rm aws_s3_bucket.tfstate aws_dynamodb_table.tfstate_lock
#        aws s3 rm s3://<bucket> --recursive
#        aws s3api delete-objects --bucket <bucket> \
#          --delete "$(aws s3api list-object-versions --bucket <bucket> \
#            --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}')"
#        aws s3api delete-objects --bucket <bucket> \
#          --delete "$(aws s3api list-object-versions --bucket <bucket> \
#            --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}')"
#        aws s3 rb s3://<bucket>
#        aws dynamodb delete-table --table-name lerian-tfstate-lock-<env>
#
#      Versioning is on, so a plain `aws s3 rb` fails until every version and
#      every delete marker is removed — hence the two delete-objects calls.
#
#   b) Temporarily comment out both `prevent_destroy = true` lines, run
#      `terraform destroy`, then restore them. Never commit the commented state.
#
# ---------------------------------------------------------------------------
# 4. Naming exception
# ---------------------------------------------------------------------------
# Every other resource in this repository is named `{product}-{env}-{component}`
# via the naming module. The state bucket cannot be: S3 bucket names are unique
# across ALL AWS accounts globally, so `lerian-dev-tfstate` would be taken by
# whoever ran this first. The bucket therefore appends the account id:
#
#   lerian-tfstate-{env}-{account_id}
#
# The DynamoDB table name is only account+region scoped, so it needs no suffix:
#
#   lerian-tfstate-lock-{env}
#
# Tags still come from the naming module unmodified.
################################################################################

provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}

module "naming" {
  source = "../_modules/naming"

  product     = "lerian"
  environment = var.environment
  component   = "tfstate"
}

locals {
  account_id = data.aws_caller_identity.current.account_id

  # Naming exception — see header section 4.
  bucket_name     = "lerian-tfstate-${var.environment}-${local.account_id}"
  lock_table_name = "lerian-tfstate-lock-${var.environment}"

  use_kms = var.kms_key_arn != ""

  # Repository-relative for humans, path.module-relative for the local provider.
  backend_config_repo_path  = "examples/aws/backend/${var.environment}.hcl"
  backend_config_write_path = "${path.module}/../backend/${var.environment}.hcl"
}

################################################################################
# State bucket
################################################################################

# S3 server access logging is deliberately off, and the exception is scoped to this
# one bucket rather than turned off for the repository.
#
# Access logging needs a SECOND bucket to receive the logs, and that bucket is
# created by the very root that bootstraps an environment — it would have to be
# protected, lifecycled and destroyed alongside the state it describes, and would
# raise the same finding about itself. What it would buy is a delayed, best-effort
# copy of a record CloudTrail already keeps: every call against this bucket is made
# with named credentials the account guard verified, and management events are
# recorded account-wide with no bucket here.
#
# Enable S3 data events on this bucket in CloudTrail if you need object-level reads
# and writes; that is the supported path, and it does not put an unprotected bucket
# next to the state.
#tfsec:ignore:aws-s3-enable-bucket-logging
resource "aws_s3_bucket" "tfstate" {
  bucket = local.bucket_name

  tags = merge(module.naming.tags, {
    Name = local.bucket_name
  })

  lifecycle {
    # See header section 3 before trying to remove this.
    prevent_destroy = true

    precondition {
      condition     = terraform.workspace == "default" || terraform.workspace == var.environment
      error_message = "Workspace/environment mismatch: workspace is '${terraform.workspace}' but environment is '${var.environment}'. Run 'terraform workspace select ${var.environment}' first, or use workspace 'default' together with an explicit -state=<env>.tfstate."
    }
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = local.use_kms ? "aws:kms" : "AES256"
      kms_master_key_id = local.use_kms ? var.kms_key_arn : null
    }

    # S3 Bucket Keys cut KMS request cost on high-volume prefixes. Meaningless
    # for AES256, hence null when no CMK is supplied.
    bucket_key_enabled = local.use_kms ? true : null
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  # Ordering: the rule set is meaningless before versioning is on, and applying
  # it first would expire nothing.
  depends_on = [aws_s3_bucket_versioning.tfstate]

  rule {
    id     = "expire-noncurrent-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_expiration_days
    }
  }

  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = var.abort_incomplete_multipart_upload_days
    }
  }
}

data "aws_iam_policy_document" "tfstate" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.tfstate.arn,
      "${aws_s3_bucket.tfstate.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  policy = data.aws_iam_policy_document.tfstate.json

  # A bucket policy with a Deny is itself "public policy" adjacent; applying it
  # before the access block is settled produces avoidable ordering churn.
  depends_on = [aws_s3_bucket_public_access_block.tfstate]
}

################################################################################
# State lock table
################################################################################

resource "aws_dynamodb_table" "tfstate_lock" {
  name         = local.lock_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = local.use_kms ? var.kms_key_arn : null
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = merge(module.naming.tags, {
    Name = local.lock_table_name
  })

  lifecycle {
    # See header section 3 before trying to remove this.
    prevent_destroy = true
  }
}

################################################################################
# Generated backend config consumed by every other stack
################################################################################

resource "local_file" "backend_config" {
  count = var.write_backend_config ? 1 : 0

  filename        = local.backend_config_write_path
  file_permission = "0640"

  content = <<-EOT
    bucket         = "${aws_s3_bucket.tfstate.id}"
    region         = "${var.region}"
    dynamodb_table = "${aws_dynamodb_table.tfstate_lock.name}"
    encrypt        = true
  EOT
}
