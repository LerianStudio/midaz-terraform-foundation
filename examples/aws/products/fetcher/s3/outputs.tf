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
# convenience scalar for "external-data", the one the chart consumes.
################################################################################

output "mode" {
  description = "Always \"dedicated\". Object storage has no shared tier: a bucket costs nothing when empty and its contents belong to exactly one product, so _modules/s3-bucket has no mode input. Emitted as a constant to keep `terraform output mode` uniform across this product's roots."
  value       = "dedicated"
}

output "eks_cluster_name" {
  description = "EKS cluster whose OIDC provider was resolved, as derived or overridden. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to fetcher. This root resolves no VPC, no subnets and no security groups — S3 is reached over the regional API endpoint, not from inside the VPC — so there are no ingress_* outputs to go with it."
  value       = module.network.eks_cluster_name
}

################################################################################
# Buckets
################################################################################

output "bucket_name" {
  description = "Real, globally unique name of the external-data bucket — the value the chart reads as OBJECT_STORAGE_BUCKET."
  value       = module.storage.bucket_names["external-data"]
}

output "bucket_arn" {
  description = "ARN of the external-data bucket."
  value       = module.storage.bucket_arns["external-data"]
}

output "bucket_regional_domain_name" {
  description = "Region specific domain name of the external-data bucket, for an SDK configured with an explicit endpoint."
  value       = module.storage.bucket_regional_domain_names["external-data"]
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
  description = "ARN of the IRSA role — the value of the eks.amazonaws.com/role-arn annotation on the fetcher-helm ServiceAccount. Null when irsa_enabled is false, in which case attach iam_policy_arns to a role the EKS stack manages instead."
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
# Verified against fetcher-helm 3.1.0 (appVersion 3.0.2), values.yaml
# `worker.configmap` (the "Storage Provider" block) and `worker.secrets`.
#
# DESTINATION NOTE, and it is the sharpest difference from reporter: the object
# storage keys live in `worker.configmap`, NOT in `common.configmap`. Only the
# worker deployment receives them — templates/worker/configmap.yaml ranges over
# .Values.worker.configmap alone. Merging these into common.configmap puts them
# on the manager as well, which is harmless but hides the fact that the manager
# has no object storage configuration today. If the manager ever needs to read
# an object, that is a CHART change, not a values change.
#
# THE SEAWEEDFS KEYS ARE REAL HERE, AND UNMAPPABLE. Unlike reporter (where
# SEAWEEDFS_* survives only in a stale values-template.yaml), this chart carries
# SEAWEEDFS_HOST, SEAWEEDFS_FILER_PORT and SEAWEEDFS_TTL in the LIVE
# common.configmap. They address the SeaweedFS filer API, which is not S3 and has
# no S3 equivalent:
#
#   SEAWEEDFS_HOST / SEAWEEDFS_FILER_PORT  a filer host and port. S3 has a
#     regional HTTPS endpoint, not a filer. Pointing SEAWEEDFS_HOST at
#     s3.amazonaws.com would name a host that speaks a different protocol.
#   SEAWEEDFS_TTL                          a filer-side object TTL. The S3
#     equivalent is a lifecycle expiration rule, which THIS ROOT already creates
#     from var.buckets (expiration_days) — server-side, not client-side.
#
# They are therefore NOT emitted. CONFIRMAR whether the application ignores them
# when STORAGE_PROVIDER is not seaweedfs; if it reads them unconditionally, the
# S3 path needs a chart change before it can be used at all.
#
# STORAGE_PROVIDER IS THE SWITCH AND ITS S3 VALUE IS UNKNOWN. values.yaml ships
# STORAGE_PROVIDER: "seaweedfs" and no template branches on it, so the accepted
# values live in the application, not in the chart. "s3" is the obvious guess and
# a guess is exactly what must not be emitted here.
#   CONFIRMAR no chart: the value of STORAGE_PROVIDER that selects the S3 driver.
#   Until it is confirmed, setting the OBJECT_STORAGE_* keys below has no effect
#   — the application keeps using the SeaweedFS driver.
#
# CONFIRMAR (same question as reporter, same answer needed): does the application
# fall back to the AWS default credential chain when OBJECT_STORAGE_ACCESS_KEY_ID
# and OBJECT_STORAGE_SECRET_KEY are empty? IRSA depends on it, and this root
# publishes iam_role_arn for the ServiceAccount annotation on that assumption.
#
# NOT emitted here, on purpose:
#   OBJECT_STORAGE_KEY_PREFIX — an application-chosen key namespace inside the
#     bucket (chart default empty). Terraform creates no prefixes.
#   OBJECT_STORAGE_ACCESS_KEY_ID / OBJECT_STORAGE_SECRET_KEY — credentials.
################################################################################

output "helm_values" {
  description = "fetcher chart env vars this bucket fills in, ready to merge into worker.configmap (NOT common.configmap). Incomplete on purpose: STORAGE_PROVIDER still has to be set to whatever value selects the S3 driver, which the chart does not document — see the CONFIRMAR notes above. The fetcher chart already ships seaweedfs.enabled = false. Annotate the worker ServiceAccount with eks.amazonaws.com/role-arn = iam_role_arn."
  value = {
    OBJECT_STORAGE_BUCKET         = module.storage.bucket_names["external-data"]
    OBJECT_STORAGE_REGION         = var.region
    OBJECT_STORAGE_ENDPOINT       = "https://s3.${var.region}.amazonaws.com"
    OBJECT_STORAGE_USE_PATH_STYLE = "false"
  }
}
