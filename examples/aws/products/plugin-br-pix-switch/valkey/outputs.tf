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
  # VALKEY_URL template, with the password left as a literal placeholder.
  #
  # The chart's example is redis://default:<password>@valkey-host:6379/0
  # (values-template.yaml:44). Three details in it are load-bearing:
  #
  #   redis://      the SCHEME the chart uses even though the engine is Valkey.
  #                 Valkey speaks the Redis wire protocol; every client library
  #                 registers the redis:// scheme. rediss:// is the TLS form and
  #                 is NOT used here — see below.
  #   default       the Redis 6+ default username. ElastiCache AUTH tokens
  #                 authenticate as this user, so it stays.
  #   /0            the logical database index. ElastiCache exposes 16 on every
  #                 node and Terraform creates none of them; 0 is the chart's
  #                 choice, carried through unchanged.
  #
  # The scheme tracks transit_encryption_mode: "required" means every client MUST
  # speak TLS, which is rediss://. At "preferred" — the default here, and what the
  # tfvars set — ElastiCache accepts both and the chart's plaintext redis:// works.
  ################################################################################
  valkey_scheme = var.transit_encryption_enabled && var.transit_encryption_mode == "required" ? "rediss" : "redis"

  valkey_url_template = "${local.valkey_scheme}://default:<password>@${module.valkey.endpoint}:${module.valkey.port}/${var.redis_db_index}"
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
  description = "EKS cluster whose node security group was looked up. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to plugin-br-pix-switch."
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
  description = "ARN of the Secrets Manager secret holding the auth token: plugin-br-pix-switch-{env}-valkey/auth-token in dedicated mode, shared-{env}-valkey/auth-token in shared mode."
  value       = module.valkey.secret_arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret holding the auth token. The token exists whether or not ElastiCache enforces it; this is the value an External Secrets Operator ExternalSecret references to populate REDIS_PASSWORD once auth_token_enabled is true."
  value       = module.valkey.secret_name
}

output "identifier" {
  description = "ElastiCache replication group id: plugin-br-pix-switch-{environment}-valkey in dedicated mode, the resolved shared-{env}-valkey in shared mode."
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
  description = "Whether in-transit encryption is enabled on the replication group. Available is not the same as required: at transit_encryption_mode = \"preferred\" ElastiCache accepts TLS and plaintext alike and valkey_url_template stays on the redis:// scheme. Only \"required\" switches it to rediss://."
  value       = module.valkey.transit_encryption_enabled
}

output "subnet_group_name" {
  description = "Name of the cache subnet group. Null in shared mode."
  value       = module.valkey.subnet_group_name
}

################################################################################
# Helm handoff — DELIBERATELY EMPTY
#
# The chart reads the cache through ONE key, and that key is a full connection
# URL living in a Secret. Verified against chart 2.0.0-beta.1+:
#
#   values-template.yaml:44,88,101   spi.secrets.VALKEY_URL,
#                                    dictHub.secrets.VALKEY_URL,
#                                    dictHubVsync.secrets.VALKEY_URL
#                                    -> "redis://default:<password>@host:6379/0"
#   values.yaml:1411-1426            "Used by spi, dict-hub, dict-hub-vsync for
#                                    VALKEY_URL (optional — caching)"; the bundled
#                                    subchart ships disabled with the comment
#                                    "For external Valkey/ElastiCache set
#                                    enabled: false and configure VALKEY_URL"
#   templates/spi/secrets.yaml:13-15 the secrets map is emitted verbatim; there is
#                                    no host key, no port key, no user key
#
# TERRAFORM CANNOT FILL A SECRET. VALKEY_URL carries the password, and this
# repository never emits a password. There is also nothing non-secret left over
# to emit: unlike Postgres and Mongo, the cache has NO bootstrap Job and
# therefore no global.external*Definitions block with a plain host and port.
#
# So helm_values is empty and valkey_url_template below carries the shape. Note
# it goes into THREE components' secrets blocks: spi, dictHub and dictHubVsync.
#
# THE PASSWORD MUST BE URL-SAFE — AND NOW IS, BY CONSTRUCTION. It is being
# interpolated into a URL, and the same characters that break a postgres:// DSN
# break this one. The valkey-elasticache module now generates the auth token as
# 32 characters from alphanumerics plus "-" only — the single character that is
# BOTH inside the ElastiCache AUTH allowlist (! & # $ ^ < > -) and RFC 3986
# unreserved. See README.md and the module README.
#
# NOT emitted here, on purpose:
#   the auth token itself — read from secret_name by External Secrets. Note it is
#     only REQUIRED once auth_token_enabled is true, which is false in every
#     environment; see README.md for why, and for what the URL looks like without
#     credentials until then.
################################################################################

output "helm_values" {
  description = "EMPTY ON PURPOSE. The chart's only cache key is VALKEY_URL — a full redis:// connection URL containing the password — read by three components (spi, dictHub, dictHubVsync) from their secrets blocks. There is no non-secret host/port surface either: unlike Postgres and Mongo the cache has no bootstrap Job. Use valkey_url_template."
  value       = {}
}

output "valkey_url_template" {
  description = "The VALKEY_URL template for spi.secrets, dictHub.secrets and dictHubVsync.secrets, with the password left as the literal placeholder <password>. Substitute the auth token from secret_name and percent-encode it if it is not URL-safe. While auth_token_enabled is false ElastiCache demands no credential and the userinfo section can be dropped entirely. The scheme is rediss:// only when transit_encryption_mode is \"required\"."
  value       = local.valkey_url_template
}
