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
  description = "THE HANDOFF VALUE. Goes on the hub ServiceAccount as eks.amazonaws.com/role-arn — on EVERY hub role's service account, not only ingest."
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
  description = "Resource ARN patterns the policy was rendered with. Read this before debugging a boot failure that talks about tenants: a roster that comes back empty because the prefix does not match looks identical to a roster that is genuinely empty."
  value       = module.secrets.secret_arn_patterns
}

output "list_secrets_granted" {
  description = "Whether the account-wide ListSecrets statement was emitted. False in multi-tenant mode means the hub will not boot."
  value       = module.secrets.list_secrets_granted
}

################################################################################
# Helm handoff
#
# streaming-hub has no chart in its repository and none in the deployer's chart
# directory — the one service of this wire where the absence was actually measured. These key names come from the service's own
# configuration loader (internal/bootstrap/config_load.go), which is the only
# authority that exists, and the chart that eventually gets written has to match
# them rather than the other way round.
#
# TWO OF THE THREE KEYS ARE UNPREFIXED, and that is a real trap rather than a
# typo. Everything else the hub reads is STREAMING_HUB_*; MULTI_TENANT_ENABLED and
# ENV_NAME are not. A STREAMING_HUB_MULTI_TENANT_ENABLED still appears in the
# service's own .env.example and HAS NO EFFECT — the hub silently stays
# single-tenant, serves one tenant, and reports nothing wrong.
#
# AWS_REGION is emitted because the hub declares no region variable of its own and
# relies entirely on the SDK default chain, with IMDS deliberately excluded. Unset
# under multi-tenancy means no roster and no boot.
################################################################################

output "helm_values" {
  description = "Chart env vars this role fills in. MULTI_TENANT_ENABLED and ENV_NAME are UNPREFIXED on purpose — the STREAMING_HUB_-prefixed spelling of the first one exists in the service's .env.example and is silently ignored. ENV_NAME must be the same literal used in secret_path_prefixes, or the roster listing matches nothing."
  value = {
    "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn" = module.secrets.iam_role_arn
    MULTI_TENANT_ENABLED                                        = var.allow_list_secrets ? "true" : "false"
    ENV_NAME                                                    = var.app_env_name
    AWS_REGION                                                  = var.region
  }
}
