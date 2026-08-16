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
# convenience scalar for "correios-attachments", the one the rail consumes.
################################################################################

output "mode" {
  description = "Always \"dedicated\". Object storage has no shared tier: a bucket costs nothing when empty and its contents belong to exactly one product, so _modules/s3-bucket has no mode input. Emitted as a constant to keep `terraform output mode` uniform across this product's roots."
  value       = "dedicated"
}

output "region" {
  description = "Region the buckets were created in. Published because the br-sfn correios rail has NO region key of its own — see the helm_values header — so if the SDK needs one explicitly it has to arrive as AWS_REGION through the rail's configmap, and this is the value to use."
  value       = var.region
}

output "eks_cluster_name" {
  description = "EKS cluster whose OIDC provider was resolved, as derived or overridden. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to br-sfn. This root resolves no VPC, no subnets and no security groups — S3 is reached over the regional API endpoint, not from inside the VPC — so there are no ingress_* outputs to go with it."
  value       = module.network.eks_cluster_name
}

################################################################################
# Buckets
################################################################################

output "bucket_name" {
  description = "Real, globally unique name of the correios-attachments bucket — the value the correios rail reads as OBJECT_STORAGE_BUCKET."
  value       = module.storage.bucket_names["correios-attachments"]
}

output "bucket_arn" {
  description = "ARN of the correios-attachments bucket."
  value       = module.storage.bucket_arns["correios-attachments"]
}

output "bucket_regional_domain_name" {
  description = "Region specific domain name of the correios-attachments bucket, for an SDK configured with an explicit endpoint."
  value       = module.storage.bucket_regional_domain_names["correios-attachments"]
}

output "bucket_names" {
  description = "Map of logical bucket name to the real, globally unique S3 bucket name. Covers every bucket in var.buckets, not just the one the rail consumes."
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
  description = "ARN of the IRSA role — the value of the eks.amazonaws.com/role-arn annotation on the br-sfn chart ServiceAccount (serviceAccount.annotations in values.yaml). Null when irsa_enabled is false, in which case attach iam_policy_arns to a role the EKS stack manages instead. NOTE the blast radius: br-sfn has ONE ServiceAccount shared by every component, so this role is assumable by every rail, not only correios — see var.service_account."
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
# EVERYTHING LANDS ON .Values.correios.configmap.
#
# THE br-sfn CHART NAMES NO OBJECT_STORAGE KEY IN ANY TEMPLATE, AND THAT IS NOT
# A PROBLEM. correios.configmap is an untyped passthrough: it is merged and
# emitted verbatim by br-sfn.componentConfigData
# (templates/_helpers.tpl:75-82 — mergeOverwrite + toYaml), lands in the
# component ConfigMap (:117-129) and reaches the container through envFrom
# (:248-260). values.schema.json declares correios.configmap as bare
# {"type":"object"} with additionalProperties: true, so there is no allowlist to
# be absent from. The commit that introduced the rail states the design intent:
# the predecessor chart used "a FIXED ALLOWLIST of 40 keys ... anything off the
# list vanished silently. br-sfn emits the map verbatim."
#
# The only occurrences of OBJECT_STORAGE in the whole br-sfn tree are two
# COMMENTED lines in values-template.yaml (:75-76), which is an operator
# skeleton the repository validator requires and Helm never renders
# (helm/.github/scripts/validate-helm-charts/main.go:270-272; the chart uses
# .Files nowhere). Treat that file as documentation, and a stale one — see the
# next paragraph.
#
# THE SKELETON IS INCOMPLETE RELATIVE TO THE BINARY. values-template.yaml lists
# only OBJECT_STORAGE_ENDPOINT and OBJECT_STORAGE_BUCKET. The same image, wired
# properly by the standalone chart, also reads OBJECT_STORAGE_PROVIDER and
# OBJECT_STORAGE_PATH_STYLE (plugin-bc-correios/templates/configmap.yaml:47-51)
# plus the credential pair OBJECT_STORAGE_ACCESS_KEY / OBJECT_STORAGE_SECRET_KEY
# (secrets.yaml:40-41). All four config keys are emitted below, because the
# binary is the contract and the skeleton is not.
#
# OBJECT_STORAGE_ENDPOINT MUST BE SET EXPLICITLY — and the reason is subtler in
# br-sfn than in the standalone chart. There, an empty value falls back to the
# in-cluster SeaweedFS service through a `default (printf ...)`. Here there is no
# template to apply a default, so an empty value is emitted as an empty string
# and whatever the binary does with that is undefined by the chart. Either way,
# empty is NOT "let the SDK resolve the endpoint". A concrete regional endpoint
# is emitted below.
#
# NO REGION KEY EXISTS for this rail, same as the standalone chart and unlike
# reporter and fetcher.
#   CONFIRMAR: how the SDK learns the region. With IRSA the EKS pod identity
#   webhook injects AWS_REGION and AWS_DEFAULT_REGION into the container, which
#   is normally enough. If the application needs it explicitly, add AWS_REGION
#   to correios.configmap — which the passthrough accepts without a chart change
#   — using the `region` output of this stack.
#
# CONFIRMAR (the same question products/plugin-bc-correios/s3, reporter and
# fetcher all ask): does the application fall back to the AWS default credential
# chain when OBJECT_STORAGE_ACCESS_KEY and OBJECT_STORAGE_SECRET_KEY are empty?
# IRSA depends on it. Note the spelling: OBJECT_STORAGE_ACCESS_KEY, without the
# _ID suffix reporter uses.
#
# NOT emitted here, on purpose:
#   OBJECT_STORAGE_ACCESS_KEY / OBJECT_STORAGE_SECRET_KEY — credentials. With
#     IRSA there is nothing to emit; the role is the credential.
#   correios.secrets.ENCRYPTION_KEY (AES-256, 32 bytes) — an application secret
#     with no Terraform counterpart, called out in ../README.md.
#   seaweedfs.enabled — br-sfn ships NO SeaweedFS resources at all (grep for
#     SEAWEED across the tree returns zero hits), unlike the standalone chart
#     where this root's counterpart has to pair its values with
#     seaweedfs.enabled = false. Nothing to switch off here.
################################################################################

output "helm_values" {
  description = "br-sfn correios-rail env vars this bucket fills in, ready to merge into the correios.configmap block. The chart types none of these keys — correios.configmap is a verbatim passthrough (templates/_helpers.tpl:75-82) — so they are emitted from the binary's contract, verified against the standalone plugin-bc-correios chart that runs the same image. Annotate the chart ServiceAccount with eks.amazonaws.com/role-arn = iam_role_arn, and note that ServiceAccount is shared by every rail. Unlike the standalone product there is no SeaweedFS to disable: br-sfn ships none."
  value = {
    OBJECT_STORAGE_PROVIDER   = "s3"
    OBJECT_STORAGE_BUCKET     = module.storage.bucket_names["correios-attachments"]
    OBJECT_STORAGE_ENDPOINT   = "https://s3.${var.region}.amazonaws.com"
    OBJECT_STORAGE_PATH_STYLE = "false"
  }
}
