################################################################################
# Outputs
#
# THE SEVEN UNIFORM DATASTORE OUTPUTS ARE DELIBERATELY ABSENT.
#
# endpoint, port, security_group_id, secret_arn, secret_name and identifier
# describe a network service reached with a connection string. S3 has no host to
# resolve, no port to open and no password to rotate — access is granted by IAM
# role, not by credential. Emitting those six names filled with null would be
# worse than not emitting them: a consumer that reads `endpoint` and gets null
# cannot tell "this datastore has no endpoint" from "the lookup failed".
#
# `mode` IS emitted, as the constant "dedicated", so tooling that reads
# `terraform output mode` across every root of this product keeps working. It is
# a constant rather than a variable because _modules/s3-bucket has no mode input
# — see the header of main.tf.
#
# Everything else is keyed by the LOGICAL bucket name from var.buckets, plus a
# convenience scalar for "migrations", the one the chart consumes.
################################################################################

output "mode" {
  description = "Always \"dedicated\". Object storage has no shared tier: a bucket costs nothing when empty and its contents belong to exactly one product, so _modules/s3-bucket has no mode input. Emitted as a constant to keep `terraform output mode` uniform across this product's roots."
  value       = "dedicated"
}

output "eks_cluster_name" {
  description = "EKS cluster whose OIDC provider was resolved, as derived or overridden. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to tenant-manager. This root resolves no VPC, no subnets and no security groups — S3 is reached over the regional API endpoint, not from inside the VPC — so there are no ingress_* outputs to go with it."
  value       = module.network.eks_cluster_name
}

################################################################################
# Buckets
################################################################################

output "bucket_name" {
  description = "Real, globally unique name of the migrations bucket — the value the service reads as MIGRATIONS_S3_BUCKET."
  value       = module.storage.bucket_names["migrations"]
}

output "bucket_arn" {
  description = "ARN of the migrations bucket."
  value       = module.storage.bucket_arns["migrations"]
}

output "bucket_regional_domain_name" {
  description = "Region specific domain name of the migrations bucket, for an SDK configured with an explicit endpoint."
  value       = module.storage.bucket_regional_domain_names["migrations"]
}

output "bucket_names" {
  description = "Map of logical bucket name to the real, globally unique S3 bucket name. Covers every bucket in var.buckets, not just the one the chart consumes."
  value       = module.storage.bucket_names
}

output "bucket_arns" {
  description = "Map of logical bucket name to bucket ARN."
  value       = module.storage.bucket_arns
}

output "bucket_ids" {
  description = "Map of logical bucket name to bucket id, as reported by AWS."
  value       = module.storage.bucket_ids
}

################################################################################
# IAM
################################################################################

output "iam_role_arn" {
  description = "ARN of the IRSA role — the value of the eks.amazonaws.com/role-arn annotation on the tenant-manager ServiceAccount. Null when irsa_enabled is false, in which case attach iam_policy_arns to a role the EKS stack manages instead."
  value       = module.storage.iam_role_arn
}

output "iam_role_name" {
  description = "Name of the IRSA role. Null when irsa_enabled is false."
  value       = module.storage.iam_role_name
}

output "iam_policy_arns" {
  description = "Map of logical bucket name to the ARN of its least-privilege access policy. One policy per bucket, so a grant can be attached and audited independently. Always populated, whether or not the role was created."
  value       = module.storage.iam_policy_arns
}

output "oidc_provider_arn" {
  description = "OIDC provider ARN the IRSA trust policy was written against, as derived from the cluster or as overridden. Empty when irsa_enabled is false. Should equal the oidc_provider_arn output of infra-base/eks — comparing the two is the cheapest way to confirm the derivation found the right cluster."
  value       = local.oidc_provider_arn
}

output "service_account" {
  description = "Kubernetes service account, in namespace:name form, that the IRSA trust policy allows. Empty when irsa_enabled is false."
  value       = local.service_account
}

################################################################################
# Helm handoff
#
# tenant-manager's chart lives in the internal gitops repository. These key names
# come from the service's configuration struct (internal/bootstrap/config.go:101-188),
# which is the authority.
#
# THERE ARE THREE BUCKET VARIABLES AND THEY ARE NOT INTERCHANGEABLE:
#
#   MIGRATIONS_S3_BUCKET         real. ListObjectsV2 + GetObject over the per-tenant
#                                migration SQL. Empty DISABLES the migration handler
#                                silently rather than failing — so a blank value
#                                gives a control plane that provisions tenants and
#                                never migrates them.
#   CASDOOR_TEMPLATE_S3_BUCKET   real. GetObject on the Casdoor application
#                                templates used during onboarding.
#   CFN_TEMPLATE_S3_BUCKET       A READINESS PROBE AND NOTHING ELSE. It buys one
#                                HeadBucket in /readyz. The CloudFormation templates
#                                are fetched over plain HTTPS from a HARDCODED
#                                PUBLIC url in sa-east-1
#                                (internal/pkg/cftemplate/url.go:23), bypassing the
#                                S3 SDK and IAM entirely. Pointing it at a bucket of
#                                ours changes nothing about where templates come
#                                from.
#
# Neither of the two real ones is emitted with a region key: the service takes a
# per-bucket region override (MIGRATIONS_S3_REGION, CASDOOR_TEMPLATE_S3_REGION) and
# leaving them unset lets the SDK resolve, which is the better default.
################################################################################

output "helm_values" {
  description = "tenant-manager env vars these buckets fill in. Note that MIGRATIONS_S3_BUCKET left EMPTY disables the migration handler silently — a control plane that onboards tenants and never migrates them, with nothing in the logs saying so. CFN_TEMPLATE_S3_BUCKET is deliberately not emitted: it drives a readiness HeadBucket only, while the real CloudFormation templates come over public HTTPS from a hardcoded sa-east-1 url."
  value = {
    MIGRATIONS_S3_BUCKET       = module.storage.bucket_names["migrations"]
    CASDOOR_TEMPLATE_S3_BUCKET = module.storage.bucket_names["casdoor-templates"]
  }
}
