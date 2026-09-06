output "role_arn" {
  description = "ARN of the upload role. This is the value that goes into the `aws_role_arn` field of the s3_uploads entry in the other repository's release.yml — the single string that ties that pipeline to the grants here."
  value       = aws_iam_role.this.arn
}

output "oidc_provider_arn" {
  description = "ARN of this account's GitHub identity provider. Emitted so a second repository's upload role can reuse it instead of registering a duplicate: AWS refuses a second identity provider for the same URL (EntityAlreadyExists)."
  value       = aws_iam_openid_connect_provider.github.arn
}

output "allowed_subject" {
  description = "The :sub pattern the trust policy admits. Echoed back so an apply's evidence names WHAT can assume the role, rather than asserting that a role exists."
  value       = "repo:${var.github_repository}:ref:refs/tags/*"
}

output "object_prefix_arns" {
  description = "The exact object ARNs s3:PutObject is granted over, one per release channel. Echoed back because the failure this root exists to prevent is a missing channel, which is invisible until a tag of that channel is cut."
  value       = local.object_prefix_arns
}
