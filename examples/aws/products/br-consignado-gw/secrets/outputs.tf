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
# Verified against br-consignado-gw's env contract (internal/bootstrap/config.go).
# A published chart exists (br-consignado-gw-helm 1.0.1, ghcr helm-internal) and
# was not read while authoring this root, so these key names are the contract the
# chart has to satisfy — reconcile against the real values.yaml in the helmfile
# phase rather than trusting either side alone.
#
# AWS_REGION IS OMITTED, NOT EMITTED EMPTY, AND THE DIFFERENCE IS NOT COSMETIC.
#
# The gateway's config declares, with the reason written down, that a literal region
# is an OVERRIDE rather than a fallback, and that for a regulated institution the
# region is data residency. So the right value is "whatever the pod resolves", and
# the way to express that is to say nothing.
#
# An empty string does NOT say nothing. AWS_REGION present-and-empty in the pod spec
# stops the EKS pod-identity webhook from injecting the real region — the webhook
# does not overwrite an env var that is already defined — so resolution falls
# through to AWS_DEFAULT_REGION and then to IMDS, neither of which is guaranteed on
# a cluster with a hop limit of 1. The result is a region lookup that fails at
# runtime, on the custody path.
#
# The sibling s3 root already omitted it and said why. This one now agrees.
################################################################################

output "helm_values" {
  description = "Chart values this role fills in. CREDENTIALS_STORE_ENABLED must be true — the gateway refuses to boot with the custody store off in a managed deployment. ENV_NAME is the segment inside every custody reference and is immutable from the first write. AWS_REGION is deliberately ABSENT rather than empty: an empty value blocks the pod-identity webhook from injecting the real region."
  value = {
    "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn" = module.secrets.iam_role_arn
    CREDENTIALS_STORE_ENABLED                                   = "true"
    ENV_NAME                                                    = var.app_env_name
  }
}
