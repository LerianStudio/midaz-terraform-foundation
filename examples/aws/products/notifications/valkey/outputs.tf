################################################################################
# Outputs
#
# The seven uniform contract names (mode, endpoint, port, security_group_id,
# secret_arn, secret_name, identifier) are passed straight through from the
# module, so every Lerian datastore root can be consumed the same way regardless
# of which datastore it wraps.
#
# There is no dns_name output and no private zone: every AWS datastore presents
# a certificate for its own service domain, so a CNAME in front of it breaks TLS
# hostname verification. `endpoint` is the raw AWS host in both modes.
#
# The module is NOT under count here — this root stack wraps exactly one
# datastore — so a plain module.valkey.x reference is safe. The one(...)
# gymnastics live inside the module, where the count actually is.
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
  description = "EKS cluster whose node security group was looked up. Should equal the cluster_name output of infra-base/eks. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to notifications."
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
  description = "Raw AWS primary endpoint of the replication group — the value of REDIS_HOST, which on this chart is a BARE HOSTNAME (REDIS_PORT is a separate variable). In shared mode this is the primary endpoint of shared-{env}-valkey, resolved by name. It is the raw endpoint on purpose: with transit encryption on, the ElastiCache certificate only covers *.{cluster}.{region}.cache.amazonaws.com."
  value       = module.valkey.endpoint
}

output "port" {
  description = "Valkey port, emitted as its own REDIS_PORT variable — this chart did not fold it into REDIS_HOST."
  value       = module.valkey.port
}

output "security_group_id" {
  description = "Security group protecting the replication group. Null in shared mode — ingress on the shared replication group is owned by products/shared-resources/valkey."
  value       = module.valkey.security_group_id
}

output "secret_arn" {
  description = "ARN of the Secrets Manager secret holding the auth token: notifications-{env}-valkey/auth-token in dedicated mode, shared-{env}-valkey/auth-token in shared mode."
  value       = module.valkey.secret_arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret holding the auth token. This is the value an External Secrets Operator ExternalSecret references."
  value       = module.valkey.secret_name
}

output "identifier" {
  description = "ElastiCache replication group id: notifications-{environment}-valkey in dedicated mode, the resolved shared-{env}-valkey in shared mode."
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

locals {
  ################################################################################
  # REDIS_TLS reflects whether TLS is REQUIRED, not whether it is available.
  #
  # transit_encryption_mode = "preferred" means ElastiCache accepts TLS and
  # plaintext clients alike, and the chart currently connects in plaintext.
  # Reporting "true" in that state would flip the service to a TLS handshake it
  # has no CA configuration for, so only "required" is reported as true.
  ################################################################################
  redis_tls_required = var.transit_encryption_enabled && var.transit_encryption_mode == "required"
}

################################################################################
# Helm handoff
#
# Verified against chart 1.0.0-beta.4 (appVersion 0.1.0), values.yaml `config`
# and `secrets`. One shared ConfigMap and one shared Secret for api and all three
# workers.
#
# REDIS_HOST IS A BARE HOSTNAME HERE. This is the trap in reverse: the midaz
# chart removed REDIS_PORT in its 3.0 and requires "host:port" inline, but
# notifications keeps REDIS_PORT as a separate key (values.yaml config, and the
# chart README documents config.REDIS_HOST as "External Redis host"). Emitting
# "host:6379" into REDIS_HOST on this chart produces a hostname with a colon in
# it, which resolves to nothing.
#
# REDIS_TLS lives in .Values.secrets, not .Values.config — see
# helm_secret_values. It is a boolean flag, not a credential; the chart just
# routes it through the Secret.
#
# NOT emitted here, on purpose:
#   REDIS_PASSWORD — read from secret_name by External Secrets, never an output.
#   REDIS_CA_CERT  — the ElastiCache CA bundle, distributed with the chart or
#     mounted from a ConfigMap, not produced by Terraform.
#   REDIS_MASTER_NAME — a Sentinel construct. ElastiCache replication groups do
#     not expose Sentinel, so there is no value to emit; the chart default (empty)
#     is correct.
#   MULTI_TENANT_REDIS_PASSWORD — same secret path as REDIS_PASSWORD, same reason.
################################################################################

output "helm_values" {
  description = "notifications chart env vars this datastore fills in, ready to merge into .Values.config (the shared ConfigMap). The chart bundles no Valkey subchart, so there is nothing to disable alongside ElastiCache."
  value = {
    REDIS_HOST = module.valkey.endpoint
    REDIS_PORT = tostring(module.valkey.port)
    REDIS_DB   = tostring(var.redis_db_index)

    # Only read when MULTI_TENANT_ENABLED is "true". Emitted regardless so
    # enabling multi-tenancy needs no second lookup; harmless when it is off.
    MULTI_TENANT_REDIS_HOST = module.valkey.endpoint
    MULTI_TENANT_REDIS_PORT = tostring(module.valkey.port)
    MULTI_TENANT_REDIS_TLS  = local.redis_tls_required ? "true" : "false"
  }
}

output "helm_secret_values" {
  description = "The same handoff, for the keys the notifications chart routes through .Values.secrets instead of .Values.config. REDIS_TLS is a flag, not a credential — the chart simply keeps it in the Secret alongside REDIS_PASSWORD and REDIS_CA_CERT."
  value = {
    REDIS_TLS = local.redis_tls_required ? "true" : "false"
  }
}
