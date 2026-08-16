################################################################################
# ⚠ THE UNDERWRITER CHART IS NOT IN THIS REPOSITORY.
#
# infrastructure/K8S/helm/charts/underwriter/ contains no Chart.yaml, no
# values.yaml and no templates/ — only a charts/ directory holding two vendored
# dependency tarballs:
#
#   charts/postgresql-16.3.5.tgz   (Bitnami postgresql, appVersion 17.2.0)
#   charts/valkey-2.4.7.tgz        (Bitnami valkey,     appVersion 8.0.2)
#
# The valkey tarball is the ONLY evidence that this product needs a cache. It
# says nothing about the env var names the application reads, because it is
# Bitnami's chart for standing a Valkey pod up, not the product's chart for
# connecting to one.
#
# CONSEQUENCE: helm_values below is DELIBERATELY EMPTY.
#
# Redis wiring is the single worst place in this repository to guess a name,
# because the same variable behaves three different ways across charts that are
# already written:
#
#   midaz                  REDIS_HOST carries "host:port"; REDIS_PORT was
#                          deleted in chart 3.0 and does not exist
#   br-consignado-gw       REDIS_HOST carries "host:port"; it is the ONLY Redis
#                          key the chart has
#   plugin-access-manager  REDIS_HOST is a BARE host and the template appends
#                          REDIS_PORT itself — passing "host:port" yields
#                          "host:port:port"
#   tracer                 no plain REDIS_* at all; only MULTI_TENANT_REDIS_HOST
#                          (bare) plus MULTI_TENANT_REDIS_PORT
#
# There is no majority to fall back on and no Lerian-wide convention. A wrong
# guess fails at connect time in production, not at plan time.
#
# TO CLOSE THIS: read the underwriter chart's values.yaml and the template that
# renders its ConfigMap. Check specifically whether the port is a separate key,
# embedded in the host, or appended by the template.
################################################################################

locals {
  # Kept even though helm_values is empty: it is the value a consumer needs the
  # moment the chart turns out to use the midaz/br-consignado-gw shape, and
  # leaving it here documents that the shape is an open question rather than an
  # oversight. It is referenced by the redis_host_port output below.
  redis_host_port = "${module.valkey.endpoint}:${module.valkey.port}"
}

################################################################################
# Cross-stack context (assert the derived strings without opening the tfvars)
################################################################################

output "vpc_name" {
  description = "tag:Name of the VPC the replication group was placed in, as derived or overridden. Should equal the vpc_name output of infra-base/vpc."
  value       = module.network.vpc_name
}

output "eks_cluster_name" {
  description = "EKS cluster whose node security group was looked up. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to underwriter."
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
  description = "Raw AWS primary endpoint of the replication group. In shared mode this is the primary endpoint of shared-{env}-valkey, resolved by name."
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
  description = "ARN of the Secrets Manager secret holding the auth token: underwriter-{env}-valkey/auth-token in dedicated mode, shared-{env}-valkey/auth-token in shared mode."
  value       = module.valkey.secret_arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret holding the auth token. The token exists whether or not ElastiCache enforces it; whether the chart can consume it is unknown."
  value       = module.valkey.secret_name
}

output "identifier" {
  description = "ElastiCache replication group id: underwriter-{environment}-valkey in dedicated mode, the resolved shared-{env}-valkey in shared mode."
  value       = module.valkey.identifier
}

################################################################################
# Valkey specifics
################################################################################

output "reader_endpoint" {
  description = "Reader endpoint of the replication group. Empty when the group has a single cache cluster."
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

output "subnet_group_name" {
  description = "Name of the cache subnet group. Null in shared mode."
  value       = module.valkey.subnet_group_name
}

################################################################################
# Handoff helpers
#
# Both candidate shapes are published so that whoever reads the chart can wire
# the release without coming back to Terraform: `endpoint` and `port` for a
# chart that keeps them split, `redis_host_port` for one that wants them joined.
# Which of the two is correct is the open question.
################################################################################

output "redis_host_port" {
  description = "\"endpoint:port\" in one string. Published as a convenience for the case where the underwriter chart turns out to follow the midaz / br-consignado-gw shape, in which the port lives inside the host variable. Do NOT use it for a chart that appends the port itself, as plugin-access-manager does — that yields host:port:port."
  value       = local.redis_host_port
}

################################################################################
# Helm handoff — EMPTY ON PURPOSE
#
# See the block at the top of this file.
################################################################################

output "helm_values" {
  description = "EMPTY BY DESIGN. The underwriter chart is not in this repository (only vendored dependency tarballs), so the env var names it reads are unknown and are not guessed here — and Redis naming in particular varies in three incompatible ways across the Lerian charts that ARE readable. Read endpoint / port / redis_host_port / secret_name individually and map them by hand once the chart is available. See the comment block at the top of outputs.tf."
  value       = {}
}
