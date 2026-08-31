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
# convenience scalar for "reporter-storage", the one the chart consumes.
################################################################################

output "mode" {
  description = "Always \"dedicated\". Object storage has no shared tier: a bucket costs nothing when empty and its contents belong to exactly one product, so _modules/s3-bucket has no mode input. Emitted as a constant to keep `terraform output mode` uniform across this product's roots."
  value       = "dedicated"
}

output "eks_cluster_name" {
  description = "EKS cluster whose OIDC provider was resolved, as derived or overridden. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to reporter. This root resolves no VPC, no subnets and no security groups — S3 is reached over the regional API endpoint, not from inside the VPC — so there are no ingress_* outputs to go with it."
  value       = module.network.eks_cluster_name
}

################################################################################
# Buckets
################################################################################

output "bucket_name" {
  description = "Real, globally unique name of the reporter-storage bucket — the value the chart reads as OBJECT_STORAGE_BUCKET."
  value       = module.storage.bucket_names["reporter-storage"]
}

output "bucket_arn" {
  description = "ARN of the reporter-storage bucket."
  value       = module.storage.bucket_arns["reporter-storage"]
}

output "bucket_regional_domain_name" {
  description = "Region specific domain name of the reporter-storage bucket, for an SDK configured with an explicit endpoint."
  value       = module.storage.bucket_regional_domain_names["reporter-storage"]
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
  description = "ARN of the IRSA role — the value of the eks.amazonaws.com/role-arn annotation on the reporter-helm ServiceAccount. Null when irsa_enabled is false, in which case attach iam_policy_arns to a role the EKS stack manages instead."
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
# Verified against reporter-helm 3.2.0 (appVersion 2.3.0), values.yaml
# `common.configmap` (the "Object Storage" block, which already ships an
# S3-shaped surface) and `secrets:`.
#
# THE DISCOVERY NOTE FOR THIS PRODUCT WAS OUT OF DATE. It listed SEAWEEDFS_HOST
# and SEAWEEDFS_FILER_PORT as the object storage contract. Those two keys exist
# only in values-template.yaml, which is STALE: values.yaml replaced them with
# OBJECT_STORAGE_*, and no template in the chart reads a SEAWEEDFS_* key. They
# are therefore not emitted here, and they should not be set — a filer host has
# no S3 equivalent, and pointing SEAWEEDFS_HOST at s3.amazonaws.com would be a
# host that speaks a different protocol on a different port.
#
# What IS the contract is genuinely S3-shaped, so the mapping is direct:
#
#   OBJECT_STORAGE_ENDPOINT        S3 regional endpoint
#   OBJECT_STORAGE_REGION          the bucket's region
#   OBJECT_STORAGE_BUCKET          the resolved, globally unique bucket name
#   OBJECT_STORAGE_USE_PATH_STYLE  false on AWS (virtual-hosted addressing)
#   OBJECT_STORAGE_DISABLE_SSL     false on AWS (the bucket policy denies plain
#                                  HTTP outright — see require_latest_tls_policy)
#
# TWO THINGS TO CONFIRM WITH THE APPLICATION TEAM before the first release.
# Neither can be settled from the chart, and both are guesses if assumed:
#
#   1. CONFIRMAR: does an EMPTY OBJECT_STORAGE_ENDPOINT make the SDK use its own
#      regional resolver? That is the better configuration on AWS — it picks up
#      dualstack, FIPS and future regional endpoints for free — but the chart
#      default is a non-empty SeaweedFS URL, so "empty means default" is not
#      demonstrated anywhere. An explicit regional endpoint is emitted below
#      because it is the value that certainly works.
#
#   2. CONFIRMAR: does the application fall back to the AWS default credential
#      chain when OBJECT_STORAGE_ACCESS_KEY_ID and OBJECT_STORAGE_SECRET_KEY are
#      EMPTY? IRSA depends on it. This root creates the role and publishes
#      iam_role_arn for the ServiceAccount annotation, but if the application
#      instead requires a static key pair, IRSA cannot be used and an access key
#      has to be issued and rotated — a different design, not a different value.
#      This is the one place where "S3 instead of SeaweedFS" is more than a host
#      change.
#
# NOT emitted here, on purpose:
#   OBJECT_STORAGE_ACCESS_KEY_ID / OBJECT_STORAGE_SECRET_KEY — credentials. With
#     IRSA they stay empty; see point 2. Terraform never emits a credential.
################################################################################

output "helm_values" {
  description = "reporter chart env vars this bucket fills in, ready to merge into common.configmap. Pair it with seaweedfs.enabled = false so the bundled SeaweedFS is not deployed alongside S3 — the reporter chart ships seaweedfs.enabled = true by DEFAULT. Annotate the ServiceAccount with eks.amazonaws.com/role-arn = iam_role_arn."
  value = {
    OBJECT_STORAGE_BUCKET         = module.storage.bucket_names["reporter-storage"]
    OBJECT_STORAGE_REGION         = var.region
    OBJECT_STORAGE_ENDPOINT       = "https://s3.${var.region}.amazonaws.com"
    OBJECT_STORAGE_USE_PATH_STYLE = "false"
    OBJECT_STORAGE_DISABLE_SSL    = "false"
  }
}
