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
# convenience scalar for "bc-correios-attachments", the one the chart consumes.
################################################################################

output "mode" {
  description = "Always \"dedicated\". Object storage has no shared tier: a bucket costs nothing when empty and its contents belong to exactly one product, so _modules/s3-bucket has no mode input. Emitted as a constant to keep `terraform output mode` uniform across this product's roots."
  value       = "dedicated"
}

output "eks_cluster_name" {
  description = "EKS cluster whose OIDC provider was resolved, as derived or overridden. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to plugin-bc-correios. This root resolves no VPC, no subnets and no security groups — S3 is reached over the regional API endpoint, not from inside the VPC — so there are no ingress_* outputs to go with it."
  value       = module.network.eks_cluster_name
}

################################################################################
# Buckets
################################################################################

output "bucket_name" {
  description = "Real, globally unique name of the bc-correios-attachments bucket — the value the chart reads as OBJECT_STORAGE_BUCKET."
  value       = module.storage.bucket_names["bc-correios-attachments"]
}

output "bucket_arn" {
  description = "ARN of the bc-correios-attachments bucket."
  value       = module.storage.bucket_arns["bc-correios-attachments"]
}

output "bucket_regional_domain_name" {
  description = "Region specific domain name of the bc-correios-attachments bucket, for an SDK configured with an explicit endpoint."
  value       = module.storage.bucket_regional_domain_names["bc-correios-attachments"]
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
  description = "ARN of the IRSA role — the value of the eks.amazonaws.com/role-arn annotation on the plugin-bc-correios-helm ServiceAccount. Null when irsa_enabled is false, in which case attach iam_policy_arns to a role the EKS stack manages instead."
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
# Verified against plugin-bc-correios-helm 2.2.0 (appVersion 1.2.0),
# templates/configmap.yaml (the "Object Storage (SeaweedFS S3)" block) and
# templates/secrets.yaml.
#
# THE DISCOVERY NOTE FOR THIS PRODUCT WAS WRONG. It listed SEAWEEDFS_HOST and
# SEAWEEDFS_FILER_PORT as the object storage contract. Neither key exists in this
# chart, in values.yaml, values-template.yaml or any template. The only place the
# string SEAWEEDFS_HOST appears is as a local shell variable inside the init
# container, derived FROM OBJECT_STORAGE_ENDPOINT:
#
#   SEAWEEDFS_HOST=$(echo "$OBJECT_STORAGE_ENDPOINT" | sed -E 's|^https?://||' ...)
#   wait_for_service "$SEAWEEDFS_HOST" "8333"
#
# — and that whole branch is wrapped in {{- if .Values.seaweedfs.enabled }}, so
# setting seaweedfs.enabled = false removes it. This is the product where the
# SeaweedFS-to-S3 move is cleanest: the chart already speaks S3.
#
# OBJECT_STORAGE_ENDPOINT MUST BE SET EXPLICITLY. templates/configmap.yaml
# renders it as
#
#   OBJECT_STORAGE_ENDPOINT: {{ ... | default (printf "http://%s-seaweedfs:8333" ...) }}
#
# so an empty value is NOT "let the SDK resolve the endpoint" — it is the
# in-cluster SeaweedFS service. That default is the reason this output emits a
# concrete regional endpoint rather than the empty string.
#
# OBJECT_STORAGE_PROVIDER is already "s3" in the chart default, and it is emitted
# below anyway so the released values are explicit rather than default-dependent.
#
# NO REGION KEY EXISTS in this chart, unlike reporter and fetcher.
#   CONFIRMAR no chart: how the SDK learns the region. With IRSA the EKS pod
#   identity webhook injects AWS_REGION and AWS_DEFAULT_REGION into the
#   container, which is normally enough — but this chart also has no
#   OBJECT_STORAGE_REGION key to fall back on if it is not. If the application
#   needs one explicitly, it has to arrive through bc-correios.extraEnvVars as
#   AWS_REGION; the value is var.region, published as the `region` output of this
#   stack.
#
# CONFIRMAR (the same question the reporter and fetcher roots ask): does the
# application fall back to the AWS default credential chain when
# OBJECT_STORAGE_ACCESS_KEY and OBJECT_STORAGE_SECRET_KEY are empty? IRSA depends
# on it. Note this chart spells the first key OBJECT_STORAGE_ACCESS_KEY, without
# the _ID suffix the other two products use — the three products do not share a
# credential contract either.
#
# NOT emitted here, on purpose:
#   OBJECT_STORAGE_ACCESS_KEY / OBJECT_STORAGE_SECRET_KEY — credentials.
################################################################################

output "helm_values" {
  description = "plugin-bc-correios chart env vars this bucket fills in, ready to merge into the bc-correios.configmap block. Pair it with seaweedfs.enabled = false, which also removes the init container's SeaweedFS wait. Annotate the ServiceAccount with eks.amazonaws.com/role-arn = iam_role_arn. OBJECT_STORAGE_ENDPOINT must be explicit: the chart defaults an empty value to the in-cluster SeaweedFS service."
  value = {
    OBJECT_STORAGE_PROVIDER   = "s3"
    OBJECT_STORAGE_BUCKET     = module.storage.bucket_names["bc-correios-attachments"]
    OBJECT_STORAGE_ENDPOINT   = "https://s3.${var.region}.amazonaws.com"
    OBJECT_STORAGE_PATH_STYLE = "false"
  }
}
