output "role_arn" {
  description = "ARN of the cross-account role. This is the value that goes into the tenant-manager ServiceAccount's eks.amazonaws.com/role-arn annotation, in the control-plane cluster's chart — the single annotation that ties the pod over there to the grants here."
  value       = aws_iam_role.this.arn
}

output "oidc_provider_arn" {
  description = "ARN of this account's copy of the peer cluster's OIDC issuer. Emitted so a second role trusting the same cluster can reuse the provider instead of registering a duplicate: AWS refuses a second identity provider for the same URL (EntityAlreadyExists)."
  value       = aws_iam_openid_connect_provider.peer_cluster.arn
}

output "sa_subject" {
  description = "ServiceAccount the trust policy admits, as namespace:name. Echoed back so an apply's evidence names the workload that can assume the role, rather than asserting that a role exists."
  value       = var.sa_subject
}
