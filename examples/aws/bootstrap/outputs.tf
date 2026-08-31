output "bucket_name" {
  description = "Name of the S3 bucket holding the Terraform state for this environment."
  value       = aws_s3_bucket.tfstate.id
}

output "bucket_arn" {
  description = "ARN of the S3 state bucket, for IAM policies that grant CI the right to read and write state."
  value       = aws_s3_bucket.tfstate.arn
}

output "dynamodb_table_name" {
  description = "Name of the DynamoDB table used for state locking in this environment."
  value       = aws_dynamodb_table.tfstate_lock.name
}

output "backend_config_path" {
  description = "Repository-relative path of the generated backend config file. Written only when write_backend_config is true."
  value       = var.write_backend_config ? local.backend_config_repo_path : null
}

output "init_command" {
  description = "Ready-to-paste terraform init for a consumer stack. Run it from the stack directory and swap the key for that stack's path — the bucket is already per-environment, so the key must NOT repeat the environment."
  value       = "terraform init -backend-config=../../backend/${var.environment}.hcl -backend-config=\"key=aws/infra-base/vpc/terraform.tfstate\""
}
