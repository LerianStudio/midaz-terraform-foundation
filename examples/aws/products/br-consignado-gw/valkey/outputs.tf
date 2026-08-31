################################################################################
# Outputs
#
# The seven uniform contract names (mode, endpoint, port, security_group_id,
# secret_arn, secret_name, identifier) are passed straight through from the
# module, unchanged, so every products/*/* root answers `terraform output` the
# same way regardless of which datastore it wraps.
#
# There is no dns_name output and no private zone: every AWS datastore presents
# a certificate for its own service domain, so a CNAME in front of it breaks TLS
# hostname verification. `endpoint` is the raw AWS host in both modes.
#
# The module is NOT under count here — this root stack wraps exactly one
# datastore — so a plain module.valkey.x reference is safe.
################################################################################

locals {
  ################################################################################
  # REDIS_HOST is "host:port", not a host.
  #
  # The br-consignado-gw chart defines NO REDIS_PORT variable — grepping REDIS
  # across the whole chart returns a single key, REDIS_HOST (values.yaml:61).
  # The port lives inside it, which the chart's own upgrade guide shows
  # verbatim: docs/UPGRADE-1.0.md:138,
  #   REDIS_HOST: "redis.cache.svc.cluster.local:6379"
  #
  # Emitting a bare hostname here produces a client that dials port 0. This is
  # the same shape as the midaz chart and the OPPOSITE of plugin-access-manager,
  # whose template appends the port itself.
  ################################################################################
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
  description = "EKS cluster whose node security group was looked up. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to br-consignado-gw."
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
  description = "Raw AWS primary endpoint of the replication group — the host HALF of REDIS_HOST. The chart wants host and port in one string, so use helm_values rather than this output directly. In shared mode this is the primary endpoint of shared-{env}-valkey, resolved by name."
  value       = module.valkey.endpoint
}

output "port" {
  description = "Valkey port. The chart has NO REDIS_PORT variable — this value is folded into REDIS_HOST by helm_values."
  value       = module.valkey.port
}

output "security_group_id" {
  description = "Security group protecting the replication group. Null in shared mode — ingress on the shared group is owned by products/shared-resources/valkey."
  value       = module.valkey.security_group_id
}

output "secret_arn" {
  description = "ARN of the Secrets Manager secret holding the auth token: br-consignado-gw-{env}-valkey/auth-token in dedicated mode, shared-{env}-valkey/auth-token in shared mode."
  value       = module.valkey.secret_arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret holding the auth token. The token exists whether or not ElastiCache enforces it, but this chart has NO Redis password variable to receive it — see the note in helm_values."
  value       = module.valkey.secret_name
}

output "identifier" {
  description = "ElastiCache replication group id: br-consignado-gw-{environment}-valkey in dedicated mode, the resolved shared-{env}-valkey in shared mode."
  value       = module.valkey.identifier
}

################################################################################
# Valkey specifics
################################################################################

output "reader_endpoint" {
  description = "Reader endpoint of the replication group. Empty when the group has a single cache cluster. The chart has no reader variable, so nothing consumes this today."
  value       = module.valkey.reader_endpoint
}

output "engine_version_actual" {
  description = "Running version of the cache engine. Null in shared mode."
  value       = module.valkey.engine_version_actual
}

output "auth_token_enabled" {
  description = "Whether ElastiCache is ENFORCING the auth token stored in secret_name. Must stay false while the chart has no Redis password variable."
  value       = module.valkey.auth_token_enabled
}

output "transit_encryption_enabled" {
  description = "Whether in-transit encryption is enabled on the replication group. Available is not the same as required, and this chart has no TLS switch at all — see transit_encryption_mode."
  value       = module.valkey.transit_encryption_enabled
}

output "subnet_group_name" {
  description = "Name of the cache subnet group. Null in shared mode."
  value       = module.valkey.subnet_group_name
}

################################################################################
# Helm handoff
#
# Verified against chart br-consignado-gw-helm 1.0.0 (appVersion
# 1.3.0-beta.36), values.yaml:61 and docs/UPGRADE-1.0.md:100,138.
#
# ONE KEY. That is not an omission — REDIS_HOST is the only Redis variable this
# chart defines anywhere. There is no REDIS_PORT, no REDIS_PASSWORD, no
# REDIS_TLS, no REDIS_DB, no REDIS_USER and no MULTI_TENANT_REDIS_* block. A
# grep for REDIS across the whole chart returns values.yaml:61,
# values-template.yaml:17 and the documentation examples, and nothing else.
#
# It lands on `api.configmap`, dumped verbatim into a ConfigMap by
# templates/api-configmap.yaml:10-11 and consumed with envFrom by the api
# Deployment. The ui component has no Redis variable.
#
# THE PORT GOES INSIDE THE HOST. See the local above.
#
# NOT emitted, because the chart has nowhere to put them:
#   REDIS_PORT     — does not exist. The port is inside REDIS_HOST.
#   REDIS_PASSWORD — does not exist. This is why auth_token_enabled stays false
#     in every environment: the token is generated and stored in Secrets
#     Manager, and there is no chart variable that could deliver it to the
#     client. Closing that gap needs a chart change first, not a tfvars change.
#   REDIS_TLS      — does not exist. Same reasoning: transit_encryption_mode
#     stays "preferred" because there is no way to tell the client to negotiate
#     TLS, so "required" would lock it out outright.
################################################################################

output "helm_values" {
  description = "br-consignado-gw chart env vars this datastore fills in, ready to merge into api.configmap. REDIS_HOST carries \"host:port\" — the chart defines no REDIS_PORT. The chart declares NO subcharts (Chart.yaml has no dependencies block), so there is no valkey.enabled to turn off."
  value = {
    REDIS_HOST = local.redis_host_port
  }
}
