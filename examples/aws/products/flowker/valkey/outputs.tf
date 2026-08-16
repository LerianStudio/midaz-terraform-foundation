################################################################################
# Outputs
#
################################################################################
# helm_values IS EMPTY, ON PURPOSE. IT IS NOT AN OVERSIGHT.
#
# flowker has no readable Helm chart:
# infrastructure/K8S/helm/charts/flowker/ contains two vendored tarballs
# (mongodb-16.4.0.tgz, valkey-0.7.4.tgz) and nothing else — no Chart.yaml, no
# values.yaml, no templates/. Both were extracted and read; the only literal
# environment variable in the valkey tarball is VALKEY_LOGLEVEL, which
# configures the upstream Valkey POD and is meaningless once the datastore is
# ElastiCache. Searching the extracted tree for REDIS_ returns zero matches.
#
# The Redis-variable shape is NOT guessable from siblings, and this datastore is
# the clearest example of why. Within this one repository:
#
#   midaz         REDIS_HOST carries "host:port" in ONE string — REDIS_PORT was
#                 removed in chart 3.0, and emitting a bare hostname produces a
#                 client that dials port 0.
#   midaz         MULTI_TENANT_REDIS_HOST / _PORT are SPLIT, in the same chart.
#   plugin-fees   only has the MULTI_TENANT_REDIS_* split form, and only renders
#                 it when MULTI_TENANT_ENABLED is "true".
#
# One chart contradicts itself between two variable families. Picking either
# shape for flowker would be a coin flip whose losing side is a silent failure.
#
# WHAT TO DO INSTEAD. `endpoint`, `port` and `secret_name` below are correct and
# sufficient: joined they give "host:port", split they give the pair. Hand them
# to the team that owns flowker, and add the helm_values map here from flowker's
# OWN values.yaml once the chart lands in this monorepo.
#
################################################################################
#
# The seven uniform contract names (mode, endpoint, port, security_group_id,
# secret_arn, secret_name, identifier) are passed straight through from the
# module, unchanged — those are infrastructure facts and are unaffected by the
# missing chart.
#
# `endpoint` is the raw ElastiCache primary endpoint on purpose: with transit
# encryption on, the certificate only covers
# *.{cluster}.{region}.cache.amazonaws.com, so a private CNAME in front of it
# would break hostname verification.
################################################################################

################################################################################
# Cross-stack context (assert the derived strings without opening the tfvars)
################################################################################

output "vpc_name" {
  description = "tag:Name of the VPC the replication group was placed in, as derived or overridden. Should equal the vpc_name output of infra-base/vpc."
  value       = module.network.vpc_name
}

output "eks_cluster_name" {
  description = "EKS cluster whose node security group was looked up. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to flowker."
  value       = module.network.eks_cluster_name
}

output "ingress_security_group_ids" {
  description = "Security groups authorised on the replication group. Empty before infra-base/eks exists unless allowed_security_group_ids was passed explicitly."
  value       = module.network.ingress_security_group_ids
}

output "ingress_cidr_blocks" {
  description = "CIDR blocks authorised on the replication group. Holds the Type=private subnet CIDRs while allow_private_subnet_cidr_ingress is true."
  value       = module.network.ingress_cidr_blocks
}

################################################################################
# Uniform datastore contract
################################################################################

output "mode" {
  description = "Provisioning mode this stack ran in: dedicated or shared."
  value       = module.valkey.mode
}

output "endpoint" {
  description = "Raw AWS primary endpoint of the replication group. In shared mode this is the primary endpoint of shared-{env}-valkey, resolved by name. Join it with `port` for a chart that wants \"host:port\", or use the two separately for a chart that splits them — which of the two flowker needs is unknown here."
  value       = module.valkey.endpoint
}

output "port" {
  description = "Valkey port."
  value       = module.valkey.port
}

output "security_group_id" {
  description = "Security group protecting the replication group. Null in shared mode — ingress on the shared group is owned by products/shared-resources/valkey."
  value       = module.valkey.security_group_id
}

output "secret_arn" {
  description = "ARN of the Secrets Manager secret holding the auth token: flowker-{env}-valkey/auth-token in dedicated mode, shared-{env}-valkey/auth-token in shared mode."
  value       = module.valkey.secret_arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret holding the auth token. The token exists whether or not ElastiCache enforces it; this is the value an External Secrets Operator ExternalSecret references once auth_token_enabled is true."
  value       = module.valkey.secret_name
}

output "identifier" {
  description = "ElastiCache replication group id: flowker-{environment}-valkey in dedicated mode, the resolved shared-{env}-valkey in shared mode."
  value       = module.valkey.identifier
}

################################################################################
# Valkey specifics
################################################################################

output "reader_endpoint" {
  description = "Reader endpoint of the replication group. Resolved from the shared group in shared mode; empty when the group has a single cache cluster."
  value       = module.valkey.reader_endpoint
}

output "engine_version_actual" {
  description = "Running version of the cache engine. Null in shared mode."
  value       = module.valkey.engine_version_actual
}

output "auth_token_enabled" {
  description = "Whether ElastiCache is ENFORCING the auth token stored in secret_name. False means the token exists but is not required."
  value       = module.valkey.auth_token_enabled
}

output "transit_encryption_enabled" {
  description = "Whether in-transit encryption is enabled on the replication group. Available is not the same as required — see transit_encryption_mode."
  value       = module.valkey.transit_encryption_enabled
}

output "transit_encryption_required" {
  description = "Whether TLS is REQUIRED rather than merely accepted. This is the value a chart's REDIS_TLS-style flag should carry — reporting \"available\" as \"required\" flips a plaintext client into a TLS handshake it has no CA configuration for."
  value       = var.transit_encryption_enabled && var.transit_encryption_mode == "required"
}

output "subnet_group_name" {
  description = "Name of the cache subnet group. Null in shared mode."
  value       = module.valkey.subnet_group_name
}

################################################################################
# Helm handoff — intentionally EMPTY. Read the header of this file.
################################################################################

output "helm_values" {
  description = "EMPTY BY DESIGN. flowker has no readable Helm chart (infrastructure/K8S/helm/charts/flowker/ holds two vendored tarballs and no Chart.yaml), so no environment variable name can be verified — and the Redis variable shape is the least guessable of all, since the midaz chart itself uses a joined \"host:port\" for REDIS_HOST and a split pair for MULTI_TENANT_REDIS_*. Consume `endpoint`, `port`, `transit_encryption_required` and `secret_name` directly and map them by hand until the chart is available."
  value       = {}
}
