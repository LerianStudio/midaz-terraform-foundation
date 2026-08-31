output "mode" {
  description = "Published as a constant so `terraform output mode` answers uniformly across every root of this product. An IAM role has no shared tier."
  value       = "dedicated"
}

output "eks_cluster_name" {
  description = "EKS cluster whose OIDC provider backs the role, as derived or overridden."
  value       = module.network.eks_cluster_name
}

output "oidc_provider_arn" {
  description = "OIDC provider the trust policy federates to."
  value       = local.oidc_provider_arn
}

output "iam_role_arn" {
  description = "THE HANDOFF VALUE. Goes on the control plane ServiceAccount as eks.amazonaws.com/role-arn. Every Lerian chart passes serviceAccount.annotations through verbatim, so this is a value, not code."
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
  description = "The namespace:name the trust policy is pinned to. This and the ServiceAccount manifest must agree exactly."
  value       = module.secrets.service_account
}

output "secret_arn_patterns" {
  description = "Resource ARN patterns the policy was rendered with. FIRST THING TO READ on an AccessDenied: the usual cause is an application ENV_NAME that does not match the environment segment written into secret_path_prefixes."
  value       = module.secrets.secret_arn_patterns
}

################################################################################
# Helm handoff
#
# tenant-manager HAS NO HELM CHART in its repository either — the chart lives in
# the internal gitops repo. These keys come from the service's own configuration
# struct (internal/bootstrap/config.go), which is the authority.
#
# ENV_NAME is a HARD BOOT REQUIREMENT and its only valid values are "staging" and
# "production". It is also the segment that selects the production fork in the
# admin credential path, so it and secret_path_prefixes have to tell the same story.
################################################################################

output "helm_values" {
  description = "Chart env vars this role fills in. ENV_NAME must be \"production\" on this estate: it is a hard boot requirement AND the switch that selects clusters/production/{dbType}/{service}/shared/admin over the shorter non-production form."
  value = {
    "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn" = module.secrets.iam_role_arn
    AWS_REGION                                                  = var.region
  }
}

output "list_secrets_granted" {
  description = "Whether the account-wide ListSecrets statement was emitted. The readiness probe lists unscoped, so false makes /readyz report the vault down."
  value       = module.secrets.list_secrets_granted
}
