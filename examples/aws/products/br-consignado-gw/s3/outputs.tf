################################################################################
# Outputs
#
# This root is shaped like products/reporter/s3, which it was derived from: no
# endpoint, no port, no secret, because S3 is a regional API endpoint reached by
# IAM rather than a host inside the VPC. The `mode` output is published as a
# constant so `terraform output mode` answers uniformly across every root.
################################################################################

output "mode" {
  description = "Published as a constant. Object storage has no shared tier: a bucket costs nothing when empty and its contents belong to exactly one product."
  value       = "dedicated"
}

output "eks_cluster_name" {
  description = "EKS cluster whose OIDC provider backs the IRSA role, as derived or overridden."
  value       = module.network.eks_cluster_name
}

################################################################################
# The bucket
################################################################################

output "bucket_name" {
  description = "Name of the averbação custody bucket. THIS IS THE AVERBACAO_ARTIFACTS_BUCKET VALUE."
  value       = module.storage.bucket_names["averbacao-artifacts"]
}

output "bucket_arn" {
  description = "ARN of the custody bucket."
  value       = module.storage.bucket_arns["averbacao-artifacts"]
}

output "bucket_regional_domain_name" {
  description = "Regional domain name of the custody bucket."
  value       = module.storage.bucket_regional_domain_names["averbacao-artifacts"]
}

output "bucket_names" {
  description = "Every bucket this root created, by logical name."
  value       = module.storage.bucket_names
}

output "bucket_arns" {
  description = "Every bucket ARN, by logical name."
  value       = module.storage.bucket_arns
}

output "object_lock" {
  description = "The WORM contract this bucket was created with, echoed so it can be asserted without opening the tfvars. THE GATEWAY CHECKS THE SAME THREE FACTS AT BOOT and refuses to start if the retention floor is not met. None of them can be changed afterwards: Object Lock is settable only at bucket creation, and objects already written under COMPLIANCE cannot be deleted by anyone, so a wrong bucket cannot even be cleaned up."
  value = {
    enabled        = try(var.buckets["averbacao-artifacts"].object_lock_enabled, false)
    mode           = try(var.buckets["averbacao-artifacts"].object_lock_mode, null)
    retention_days = try(var.buckets["averbacao-artifacts"].object_lock_days, null)
  }
}

################################################################################
# IRSA
################################################################################

output "iam_role_arn" {
  description = "THE HANDOFF VALUE for object storage. Goes on the gateway ServiceAccount as eks.amazonaws.com/role-arn. NOTE: this is a SECOND role, distinct from the one products/br-consignado-gw/secrets creates. A ServiceAccount carries exactly one role-arn annotation, so either the two policies get attached to one role, or the chart gives the custody writer and the vault reader different service accounts. Decide this before the helmfile phase — it is the commonest way an IRSA estate ends up half-working."
  value       = module.storage.iam_role_arn
}

output "iam_role_name" {
  description = "Name of the IRSA role created for the bucket."
  value       = module.storage.iam_role_name
}

output "iam_policy_arns" {
  description = "Per-bucket IAM policy ARNs. ATTACHABLE ELSEWHERE, which is the way out of the two-roles problem above: attach this policy to the role from products/br-consignado-gw/secrets and set irsa_enabled = false here."
  value       = module.storage.iam_policy_arns
}

output "oidc_provider_arn" {
  description = "OIDC provider the trust policy federates to."
  value       = local.oidc_provider_arn
}

output "service_account" {
  description = "The namespace:name the trust policy is pinned to."
  value       = local.service_account
}

################################################################################
# Helm handoff
#
# br-consignado-gw ships no Helm chart, so these key names come from its own
# configuration surface (internal/bootstrap/config.go:311-317), which is the
# authority the chart will have to match.
#
# AWS_REGION IS DELIBERATELY OMITTED HERE. The gateway reads ONE region variable
# for the whole process, and products/br-consignado-gw/secrets emits it as the
# empty string on purpose — a literal region is an override, not a fallback, and on
# a regulated money path the region is data residency. Emitting a region from this
# root too would produce two sources for one value, and the S3 one would silently
# win or lose depending on merge order.
################################################################################

output "helm_values" {
  description = "Chart env vars this bucket fills in. AWS_REGION is intentionally NOT emitted here: the gateway uses one region for the whole process and products/br-consignado-gw/secrets owns that value, deliberately blank so the SDK resolves the pod's own region."
  value = {
    AVERBACAO_ARTIFACTS_BUCKET         = module.storage.bucket_names["averbacao-artifacts"]
    AVERBACAO_ARTIFACTS_USE_PATH_STYLE = "false"
  }
}
