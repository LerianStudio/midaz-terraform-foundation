################################################################################
# Outputs
#
# The seven uniform contract names (mode, endpoint, port, security_group_id,
# secret_arn, secret_name, identifier) are passed straight through from the
# datastore module, so every product root looks the same regardless of which
# datastore it wraps.
#
# There is no dns_name output and no private zone: every AWS datastore presents
# a certificate for its own service domain, so a CNAME in front of it breaks TLS
# hostname verification. `endpoint` is the raw AWS host in both modes.
#
# The module is NOT under count here — this root stack wraps exactly one
# replication group — so a plain module.valkey.x reference is safe. The
# one(...) gymnastics live inside the module, where the count actually is.
################################################################################

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
  description = "EKS cluster whose node security group was looked up. Should equal the cluster_name output of infra-base/eks. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to fetcher."
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
  description = "Raw AWS primary endpoint of the replication group. In shared mode this is the primary endpoint of shared-{env}-valkey, resolved by name. It is the raw endpoint on purpose: with transit encryption on, the ElastiCache certificate only covers *.{cluster}.{region}.cache.amazonaws.com."
  value       = module.valkey.endpoint
}

output "port" {
  description = "Valkey port."
  value       = module.valkey.port
}

output "security_group_id" {
  description = "Security group protecting the replication group. Null in shared mode — ingress on the shared one is owned by products/shared-resources/valkey."
  value       = module.valkey.security_group_id
}

output "secret_arn" {
  description = "ARN of the Secrets Manager secret holding the auth token: fetcher-{env}-valkey/auth-token in dedicated mode, shared-{env}-valkey/auth-token in shared mode."
  value       = module.valkey.secret_arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret holding the auth token. The token exists whether or not ElastiCache enforces it; this is the value an External Secrets Operator ExternalSecret references once auth_token_enabled is true."
  value       = module.valkey.secret_name
}

output "identifier" {
  description = "ElastiCache replication group id: fetcher-{environment}-valkey in dedicated mode, the resolved shared-{env}-valkey in shared mode."
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

output "subnet_group_name" {
  description = "Name of the cache subnet group. Null in shared mode."
  value       = module.valkey.subnet_group_name
}

################################################################################
# Helm handoff
#
# Verified against fetcher-helm 3.1.0 (appVersion 3.0.2), values.yaml
# `common.configmap` (the Redis/Valkey block), rendered by
# templates/common/configmap.yaml.
#
# ┌──────────────────────────────────────────────────────────────────────────┐
# │ REDIS_HOST IS A BARE HOST HERE, AND REDIS_PORT EXISTS.                    │
# │                                                                          │
# │   midaz     REDIS_HOST = "host:port"   no REDIS_PORT key at all          │
# │   reporter  REDIS_HOST = "host:port"   no REDIS_PORT key at all          │
# │   fetcher   REDIS_HOST = "host"        REDIS_PORT = "6379"               │
# │                                                                          │
# │ The two near-twin charts disagree on this. values.yaml ships             │
# │ REDIS_HOST: "valkey" and REDIS_PORT: "6379" as separate keys, so the     │
# │ combined form would be parsed as a hostname containing a colon.          │
# └──────────────────────────────────────────────────────────────────────────┘
#
# The complete Redis surface of this chart is REDIS_HOST, REDIS_PORT and
# REDIS_DB in common.configmap, plus REDIS_USER and REDIS_PASSWORD in the
# top-level secrets map. There is no REDIS_TLS and no REDIS_CA_CERT.
#
# NOT emitted here, on purpose:
#   REDIS_TLS      — DOES NOT EXIST in this chart, in any form. That is why
#     transit_encryption_mode is left at "preferred": the application has no way
#     to be told to speak TLS, so "required" would refuse every connection it
#     makes. CONFIRMAR with the chart owners before hardening.
#   REDIS_PASSWORD — read from secret_name by External Secrets. The key DOES
#     exist here (unlike reporter), so auth_token_enabled = true is reachable
#     once the ExternalSecret is wired.
#   REDIS_USER     — ElastiCache RBAC user. This module creates no RBAC user, so
#     Terraform has no value for it; the chart default (empty) means the default
#     user, which is what the auth token authenticates.
################################################################################

output "helm_values" {
  description = "fetcher chart env vars this datastore fills in, ready to merge into common.configmap. The fetcher chart already ships valkey.enabled = false, so nothing has to be turned off. Note REDIS_HOST and REDIS_PORT are SPLIT in this chart — see the header."
  value = {
    REDIS_HOST = module.valkey.endpoint
    REDIS_PORT = tostring(module.valkey.port)
    REDIS_DB   = tostring(var.redis_db_index)
  }
}
