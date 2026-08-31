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
  description = "THE HANDOFF VALUE. Goes on the gateway ServiceAccount as eks.amazonaws.com/role-arn. Every Lerian chart passes serviceAccount.annotations through verbatim, so this is a value, not code."
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
# Verified against br-consignado-gw's env contract (internal/bootstrap/config.go),
# not against a chart: the gateway HAS NO HELM CHART in its repository, so these
# key names come from the application's own configuration surface, which is the
# only authority there is.
#
# AWS_REGION IS DELIBERATELY EMITTED EMPTY. The gateway's config declares, with the
# reason written down, that a literal region is an OVERRIDE rather than a fallback,
# and that for a regulated institution the region is data residency. Left blank, the
# SDK resolves it from the pod's own environment, which is the account and region
# the workload actually runs in. An operator who hardcodes a region here can silently
# move a Dataprev credential to another jurisdiction.
################################################################################

output "helm_values" {
  description = "Chart values this role fills in. CREDENTIALS_STORE_ENABLED must be true — the gateway refuses to boot with the custody store off in a managed deployment. AWS_REGION is intentionally the empty string: a literal is an override, not a fallback, and region is data residency here."
  value = {
    "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn" = module.secrets.iam_role_arn
    CREDENTIALS_STORE_ENABLED                                   = "true"
    AWS_REGION                                                  = ""
  }
}
