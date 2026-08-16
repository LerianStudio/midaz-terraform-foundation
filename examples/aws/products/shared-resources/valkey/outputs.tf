################################################################################
# Outputs
#
# The seven uniform contract names (mode, endpoint, port, security_group_id,
# secret_arn, secret_name, identifier) are passed straight through from the
# module, so an operator script reads this stack the same way regardless of
# which datastore it wraps.
#
# There is no dns_name output and no private zone: with transit encryption on,
# the ElastiCache certificate only covers
# *.{cluster}.{region}.cache.amazonaws.com, so a CNAME in front of it breaks TLS
# hostname verification. `endpoint` is the raw AWS host.
#
# There is no `valkey_enabled` output any more. It existed when this tier was
# one root with five toggles; enablement is now "this directory was applied".
# The former `valkey_auth_token_enforced` output is `auth_token_enabled` here.
#
# The module is NOT under count here — this root wraps exactly one datastore —
# so a plain module.valkey.x reference is safe.
#
# Products do NOT read this state with terraform_remote_state. They resolve the
# shared tier by NAME — data "aws_elasticache_replication_group" on
# shared-{env}-valkey plus the Secrets Manager entry.
################################################################################

locals {
  ################################################################################
  # REDIS_HOST is "host:port", not a host.
  #
  # The midaz chart REMOVED the REDIS_PORT variable in chart 3.0 and requires the
  # port to be embedded in REDIS_HOST (docs/UPGRADE-3.0.md: "Its value must now be
  # included directly in the REDIS_HOST variable as <host>:<port>"). Emitting a
  # bare hostname there produces a ledger that dials port 0.
  ################################################################################
  redis_host_port = "${module.valkey.endpoint}:${module.valkey.port}"

  ################################################################################
  # REDIS_TLS reflects whether TLS is REQUIRED, not whether it is available.
  #
  # transit_encryption_mode = "preferred" means ElastiCache accepts TLS and
  # plaintext clients alike, and the Lerian charts currently connect in plaintext.
  # Reporting "true" in that state would flip a consumer to a TLS handshake it has
  # no CA configuration for, so only "required" is reported as true.
  ################################################################################
  redis_tls_required = var.transit_encryption_enabled && var.transit_encryption_mode == "required"
}

################################################################################
# Cross-stack context (assert the derived strings without opening the tfvars)
################################################################################

output "vpc_name" {
  description = "tag:Name of the VPC the replication group was placed in, as derived or overridden. Should equal the vpc_name output of infra-base/vpc."
  value       = module.network.vpc_name
}

output "eks_cluster_name" {
  description = "EKS cluster whose node security group was looked up. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to this tier."
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
  description = "Provisioning mode the module ran in. Always \"dedicated\" here: this stack CREATES the shared group. Products consume it with mode = \"shared\" — see the header of main.tf."
  value       = module.valkey.mode
}

output "endpoint" {
  description = "Raw AWS primary endpoint of the shared replication group — the host half of REDIS_HOST. Raw on purpose: with transit encryption on, the ElastiCache certificate only covers *.{cluster}.{region}.cache.amazonaws.com."
  value       = module.valkey.endpoint
}

output "port" {
  description = "Valkey port. The midaz chart has no REDIS_PORT variable — see helm_values."
  value       = module.valkey.port
}

output "security_group_id" {
  description = "Security group protecting the shared replication group — the one the upstream ElastiCache module attaches, not an orphan. This stack owns its ingress; a product consuming with mode = \"shared\" gets null from its own module."
  value       = module.valkey.security_group_id
}

output "secret_arn" {
  description = "ARN of shared-{environment}-valkey/auth-token."
  value       = module.valkey.secret_arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret holding the auth token. The token exists whether or not ElastiCache enforces it. This is the exact name valkey-elasticache resolves in shared mode, and the value an External Secrets Operator ExternalSecret references to populate REDIS_PASSWORD once auth_token_enabled is true."
  value       = module.valkey.secret_name
}

output "identifier" {
  description = "ElastiCache replication group id, shared-{environment}-valkey. This is the name a shared consumer resolves with data \"aws_elasticache_replication_group\"."
  value       = module.valkey.identifier
}

################################################################################
# Valkey specifics
################################################################################

output "reader_endpoint" {
  description = "Reader endpoint of the shared replication group. Empty when the group has a single cache cluster."
  value       = module.valkey.reader_endpoint
}

output "engine_version_actual" {
  description = "Running version of the cache engine."
  value       = module.valkey.engine_version_actual
}

output "auth_token_enabled" {
  description = "Whether ElastiCache is ENFORCING the auth token stored in secret_name. False means the token exists but is not required — the current state everywhere, because the Lerian charts have no Valkey AUTH client configuration yet."
  value       = module.valkey.auth_token_enabled
}

output "transit_encryption_enabled" {
  description = "Whether in-transit encryption is enabled on the replication group. Available is not the same as required — see transit_encryption_mode and the REDIS_TLS value in helm_values."
  value       = module.valkey.transit_encryption_enabled
}

output "subnet_group_name" {
  description = "Name of the cache subnet group."
  value       = module.valkey.subnet_group_name
}

################################################################################
# Helm handoff
#
# SCOPE WARNING. These are the env var names of the midaz chart, verified
# against chart 8.7.0 (appVersion 3.8.0), templates/ledger/configmap.yaml. This
# tier is consumed by ANY product, and products/midaz/README.md is explicit that
# other Lerian charts must not be assumed to use the same names — REDIS_HOST
# carrying "host:port" is a midaz-chart convention, not a Lerian-wide one. The
# FACTS below — host, port, whether TLS is required — are tier-level and
# identical for every consumer.
#
# Two shapes that look like mistakes and are not:
#   REDIS_HOST carries "host:port" — the chart dropped REDIS_PORT in 3.0.
#   MULTI_TENANT_REDIS_HOST / MULTI_TENANT_REDIS_PORT are split, unlike the pair
#     above. Those two are only rendered when MULTI_TENANT_ENABLED is "true".
#
# NOT emitted here, on purpose:
#   REDIS_PASSWORD — read from secret_name by External Secrets, never an output.
#   REDIS_CA_CERT  — the ElastiCache CA bundle, distributed with the chart.
#   REDIS_USER / REDIS_USERNAME — do not exist in the chart, in any form.
#
# REDIS_DB is emitted from var.redis_db_index. On a SHARED group the logical
# database index is the crudest available isolation between consumers, and
# coordinating it is an application concern this stack cannot enforce.
################################################################################

output "helm_values" {
  description = "Chart env vars this datastore fills in (midaz naming — see the header), ready to merge into ledger.configmap. Pair it with valkey.enabled = false and valkey.external = true so the bundled Bitnami subchart is not deployed alongside ElastiCache."
  value = {
    REDIS_HOST = local.redis_host_port
    REDIS_TLS  = local.redis_tls_required ? "true" : "false"
    REDIS_DB   = tostring(var.redis_db_index)

    MULTI_TENANT_REDIS_HOST = module.valkey.endpoint
    MULTI_TENANT_REDIS_PORT = tostring(module.valkey.port)
    MULTI_TENANT_REDIS_TLS  = local.redis_tls_required ? "true" : "false"
  }
}
