output "iam_role_arn" {
  description = "ARN of the IRSA role. THIS IS THE HANDOFF VALUE: it goes on the pod's ServiceAccount as the eks.amazonaws.com/role-arn annotation. Every Lerian chart passes serviceAccount.annotations through verbatim, so wiring it is a value, not code."
  value       = aws_iam_role.this.arn
}

output "iam_role_name" {
  description = "Name of the IRSA role, {product}-{environment}-{component}-irsa."
  value       = aws_iam_role.this.name
}

output "iam_policy_arn" {
  description = "ARN of the policy attached to the role, for a caller that wants to attach it elsewhere too."
  value       = aws_iam_policy.this.arn
}

output "service_account" {
  description = "The namespace:name the trust policy is pinned to. A pod under any other service account cannot assume this role, so this value and the ServiceAccount manifest have to agree exactly."
  value       = var.service_account
}

output "secret_arn_patterns" {
  description = "The resource ARN patterns the scoped statement was rendered with, wildcard included. Read this before debugging an AccessDenied: the commonest cause is an application ENV_NAME that does not match the environment segment written into secret_path_prefixes."
  value       = local.secret_arns
}

output "list_secrets_granted" {
  description = "Whether the account-wide secretsmanager:ListSecrets statement was emitted. streaming-hub refuses to boot without it in multi-tenant mode, and reports the refusal as a crashloop rather than as a permission error."
  value       = var.allow_list_secrets
}

output "helm_values" {
  description = "Chart values this role fills in. The annotation key is the EKS-mandated one; the value is the role ARN. Nothing else about this role reaches the chart."
  value = {
    "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn" = aws_iam_role.this.arn
  }
}
