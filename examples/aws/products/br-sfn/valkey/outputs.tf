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
# datastore — so a plain module.valkey.x reference is safe. The one(...)
# gymnastics live inside the module, where the count actually is.
################################################################################

locals {
  ################################################################################
  # CACHE_ADDR is "host:port", in one string.
  #
  # The br-sfn chart names exactly one cache variable and it is scoped to the
  # correios rail: correios.configmap.CACHE_ADDR, documented in
  # values-template.yaml:74 as "valkey/redis host:port". There is no CACHE_HOST /
  # CACHE_PORT pair to split it into.
  ################################################################################
  cache_addr = "${module.valkey.endpoint}:${module.valkey.port}"
}

################################################################################
# Cross-stack context (assert the derived strings without opening the tfvars)
#
# Re-exported from module.network, which owns the derivation. Note the "lerian"
# prefix on the VPC and the cluster: those are FOUNDATION names and keep it,
# while the shared datastore tier carries "shared".
################################################################################

output "vpc_name" {
  description = "tag:Name of the VPC the replication group was placed in, as derived or overridden. Should equal the vpc_name output of infra-base/vpc."
  value       = module.network.vpc_name
}

output "eks_cluster_name" {
  description = "EKS cluster whose node security group was looked up. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to br-sfn."
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
  description = "Raw AWS primary endpoint of the replication group — the host half of REDIS_HOST. In shared mode this is the primary endpoint of shared-{env}-valkey, resolved by name. It is the raw endpoint on purpose: with transit encryption on, the ElastiCache certificate only covers *.{cluster}.{region}.cache.amazonaws.com."
  value       = module.valkey.endpoint
}

output "port" {
  description = "Valkey port. The chart has no REDIS_PORT variable — see helm_values."
  value       = module.valkey.port
}

output "security_group_id" {
  description = "Security group protecting the replication group. Null in shared mode — ingress on the shared group is owned by products/shared-resources/valkey."
  value       = module.valkey.security_group_id
}

output "secret_arn" {
  description = "ARN of the Secrets Manager secret holding the auth token: br-sfn-{env}-valkey/auth-token in dedicated mode, shared-{env}-valkey/auth-token in shared mode."
  value       = module.valkey.secret_arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret holding the auth token. The token exists whether or not ElastiCache enforces it; this is the value an External Secrets Operator ExternalSecret references to populate REDIS_PASSWORD once auth_token_enabled is true."
  value       = module.valkey.secret_name
}

output "identifier" {
  description = "ElastiCache replication group id: br-sfn-{environment}-valkey in dedicated mode, the resolved shared-{env}-valkey in shared mode."
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
  description = "Whether in-transit encryption is enabled on the replication group. Available is not the same as required, and the difference is not communicable to this chart: its only cache key is CACHE_ADDR, a host:port string with no TLS switch, so the mode stays \"preferred\". See transit_encryption_mode."
  value       = module.valkey.transit_encryption_enabled
}

output "subnet_group_name" {
  description = "Name of the cache subnet group. Null in shared mode."
  value       = module.valkey.subnet_group_name
}

################################################################################
# Helm handoff
#
# Verified against br-sfn chart 1.1.0 (appVersion 1.0.0-beta.1).
#
# READ THIS BEFORE WIRING ANYTHING. The br-sfn chart has NO fixed env allowlist:
# <component>.configmap and <component>.secrets are emitted VERBATIM into each
# component's ConfigMap and Secret (README.md:66-72). That means the chart only
# *names* the variables its own templates read — and for the cache it names
# exactly ONE, on exactly ONE rail:
#
#   values-template.yaml:74   correios.configmap.CACHE_ADDR  "valkey/redis host:port"
#
# A grep for CACHE_ADDR, REDIS_, VALKEY_ or MULTI_TENANT over the entire chart
# (values.yaml, values-template.yaml, values.schema.json and every template)
# returns that single line and nothing else.
#
# WHAT IS NOT KNOWN, AND IS NOT GUESSED HERE:
#
# The chart README states that the four SPI components "ride one Postgres, one
# Redis and one RedPanda" (README.md:40-42) — so SPI DOES use this cache. But no
# SPI cache variable is named anywhere in the chart, because it arrives through
# spi.configmap, which the chart passes through untouched. The name lives in the
# br-sfn application repository, not in the chart.
#
#   # CONFIRMAR no chart: the cache env var name(s) read by spi (api, dict,
#   # brcode, core), and by siloc/spb/scr/desk if they use a cache at all. The
#   # chart cannot answer this; the br-sfn service owners can. Until then the
#   # endpoint and port outputs above carry the value and the operator names the
#   # key in the component's own configmap block.
#
# Emitting a guessed key here would be worse than emitting nothing: a verbatim
# passthrough means a wrong name lands in the ConfigMap silently and the rail
# falls back to whatever default it compiles in.
#
# NOT emitted here, on purpose:
#   the cache password — correios.secrets carries no cache password key at all
#     (values-template.yaml:77-80 lists POSTGRES_PASSWORD, ENCRYPTION_KEY and
#     RABBITMQ_URL). This is consistent with auth_token_enabled = false in the
#     tfvars: there is nowhere to put an ElastiCache AUTH token today.
################################################################################

output "helm_values" {
  description = "br-sfn chart env vars this datastore fills in. ONE KEY, and it belongs to the correios rail only: merge it into correios.configmap. Every other rail's cache variable name is unknown from the chart — see the header and outputs endpoint/port. This chart ships no Valkey subchart, so there is nothing to disable."
  value = {
    CACHE_ADDR = local.cache_addr
  }
}
