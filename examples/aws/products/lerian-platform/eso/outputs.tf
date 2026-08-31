output "mode" {
  description = "Published as a constant so `terraform output mode` answers uniformly. An IAM role has no shared tier."
  value       = "dedicated"
}

output "eks_cluster_name" {
  description = "EKS cluster whose OIDC provider backs the role."
  value       = module.network.eks_cluster_name
}

output "oidc_provider_arn" {
  description = "OIDC provider the trust policy federates to."
  value       = local.oidc_provider_arn
}

output "iam_role_arn" {
  description = "THE HANDOFF VALUE. Goes on the External Secrets Operator ServiceAccount as eks.amazonaws.com/role-arn, and again in the ClusterSecretStore's auth.jwt.serviceAccountRef if the store authenticates per-namespace."
  value       = module.secrets.iam_role_arn
}

output "iam_role_name" {
  description = "Name of the IRSA role."
  value       = module.secrets.iam_role_name
}

output "iam_policy_arn" {
  description = "ARN of the policy attached to the role."
  value       = module.secrets.iam_policy_arn
}

output "service_account" {
  description = "The namespace:name the trust policy is pinned to."
  value       = module.secrets.service_account
}

output "secret_arn_patterns" {
  description = "Resource ARN patterns the policy was rendered with. An ExternalSecret stuck in SecretSyncedError is almost always a path outside these, or a CMK missing from kms_key_arns."
  value       = module.secrets.secret_arn_patterns
}

################################################################################
# Helm handoff
#
# The operator is installed by Helm in the phase after this one. What Terraform
# hands over is the role ARN and the region; everything else about the
# ClusterSecretStore is chart configuration.
################################################################################

output "helm_values" {
  description = "Values for the external-secrets chart. The region is explicit because a ClusterSecretStore names its region rather than inheriting one from the pod."
  value = {
    "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn" = module.secrets.iam_role_arn
    AWS_REGION                                                  = var.region
  }
}
