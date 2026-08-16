variable "environment" {
  description = "Deployment environment. One of dev, stg or prd. Run this stack once per environment: each environment gets its own state bucket and its own lock table."
  type        = string

  validation {
    condition     = contains(["dev", "stg", "prd"], var.environment)
    error_message = "The environment must be one of: dev, stg, prd."
  }
}

variable "region" {
  description = "AWS region where the state bucket and the lock table are created. This value is written verbatim into the generated backend config, so every stack that consumes the backend must resolve its state in this region."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", var.region))
    error_message = "The region must be a valid AWS region identifier, e.g. us-east-1 or sa-east-1."
  }
}

variable "kms_key_arn" {
  description = "Optional customer managed KMS key ARN used to encrypt the state bucket objects and the lock table. Empty string (the default) keeps SSE-S3 (AES256) on the bucket and the AWS owned key on DynamoDB, which is enough for Terraform state and costs nothing."
  type        = string
  default     = ""

  validation {
    condition     = var.kms_key_arn == "" || can(regex("^arn:aws[a-zA-Z-]*:kms:", var.kms_key_arn))
    error_message = "The kms_key_arn must be empty or a valid KMS key ARN starting with arn:aws:kms:."
  }
}

variable "noncurrent_version_expiration_days" {
  description = "Number of days a noncurrent state version is retained before expiring. State files are small and old versions are the only recovery path for a corrupted apply, so do not set this aggressively low."
  type        = number
  default     = 90

  validation {
    condition     = var.noncurrent_version_expiration_days >= 7
    error_message = "The noncurrent_version_expiration_days must be at least 7 to keep a usable recovery window for corrupted state."
  }
}

variable "abort_incomplete_multipart_upload_days" {
  description = "Number of days before an incomplete multipart upload is aborted and its parts deleted. Prevents orphaned parts from accumulating as unbilled-but-charged storage."
  type        = number
  default     = 7

  validation {
    condition     = var.abort_incomplete_multipart_upload_days >= 1
    error_message = "The abort_incomplete_multipart_upload_days must be at least 1."
  }
}

variable "write_backend_config" {
  description = "When true, writes examples/aws/backend/{environment}.hcl with the generated backend settings so every other stack can be initialised with -backend-config. Set to false to run the stack read-only against the filesystem (for example when applying from CI that has no write access to the repository checkout)."
  type        = bool
  default     = true
}
