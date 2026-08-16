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
  description = "EKS cluster whose node security group was looked up. Should equal the cluster_name output of infra-base/eks. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to plugin-br-bank-transfer."
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
  description = "Raw AWS primary endpoint of the replication group — the HOST HALF of REDIS_HOST, which this chart expects as host:port in one string. In shared mode this is the primary endpoint of shared-{env}-valkey, resolved by name. It is the raw endpoint on purpose: with transit encryption on, the ElastiCache certificate only covers *.{cluster}.{region}.cache.amazonaws.com."
  value       = module.valkey.endpoint
}

output "port" {
  description = "Valkey port. The chart has no REDIS_PORT variable — helm_values folds this into REDIS_HOST."
  value       = module.valkey.port
}

output "security_group_id" {
  description = "Security group protecting the replication group. Null in shared mode — ingress on the shared replication group is owned by products/shared-resources/valkey."
  value       = module.valkey.security_group_id
}

output "secret_arn" {
  description = "ARN of the Secrets Manager secret holding the auth token: plugin-br-bank-transfer-{env}-valkey/auth-token in dedicated mode, shared-{env}-valkey/auth-token in shared mode."
  value       = module.valkey.secret_arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret holding the auth token. This is the value an External Secrets Operator ExternalSecret references."
  value       = module.valkey.secret_name
}

output "identifier" {
  description = "ElastiCache replication group id: plugin-br-bank-transfer-{environment}-valkey in dedicated mode, the resolved shared-{env}-valkey in shared mode."
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
  # REDIS_HOST is "host:port", not a host.
  #
  # This chart has NO REDIS_PORT key. The proof is not the default value alone
  # (templates/configmap.yaml defaults REDIS_HOST to
  # "<release>-valkey-primary.<ns>.svc.cluster.local:6379") but the init
  # container in templates/deployment.yaml, which splits the variable itself:
  #
  #     REDIS_SVC=$(echo "$REDIS_HOST" | cut -d: -f1)
  #     REDIS_PORT_NUM=$(echo "$REDIS_HOST" | cut -d: -f2)
  #     wait_for_service "$REDIS_SVC" "$REDIS_PORT_NUM"
  #
  # Emitting a bare hostname here makes that cut return the hostname twice and
  # the readiness gate dials the host as if it were a port number.
  #
  # This happens to match the midaz chart and NOT the notifications chart, which
  # keeps REDIS_PORT separate. There is no Lerian-wide convention; each chart has
  # to be read.
  ################################################################################
  redis_host_port = "${module.valkey.endpoint}:${module.valkey.port}"

  ################################################################################
  # REDIS_TLS reflects whether TLS is REQUIRED, not whether it is available.
  #
  # transit_encryption_mode = "preferred" means ElastiCache accepts TLS and
  # plaintext clients alike, and the plugin currently connects in plaintext.
  # Reporting "true" in that state would flip it to a TLS handshake it has no CA
  # configuration for.
  ################################################################################
  redis_tls_required = var.transit_encryption_enabled && var.transit_encryption_mode == "required"
}

################################################################################
# Helm handoff
#
# Verified against chart 1.5.0 (appVersion 1.2.1), templates/configmap.yaml and
# templates/deployment.yaml.
#
# The REDIS_* block is one of the few that templates/configmap.yaml renders in
# BOTH single-tenant and multi-tenant mode — only the pool/timeout tuning is
# gated behind {{- if not $multiTenantEnabled }}. So REDIS_HOST, REDIS_DB and
# REDIS_TLS below apply either way, and the MULTI_TENANT_REDIS_* trio is read
# only when MULTI_TENANT_ENABLED is "true" (where the chart marks
# MULTI_TENANT_REDIS_HOST required()).
#
# PAIR IT WITH BOTH SUBCHART SWITCHES:
#     valkey:
#       enabled:  false
#       external: true
# `external: true` is what moves REDIS_PASSWORD resolution off the subchart
# Secret and onto the chart's own — templates/deployment.yaml picks the source
# from exactly that flag.
#
# NOT emitted here, on purpose:
#   REDIS_PASSWORD / MULTI_TENANT_REDIS_PASSWORD — read from secret_name by
#     External Secrets, never an output.
#   REDIS_CA_CERT — the ElastiCache CA bundle, distributed with the chart or
#     mounted from a ConfigMap, not produced by Terraform.
#   REDIS_MASTER_NAME — a Sentinel construct. ElastiCache replication groups
#     expose no Sentinel, so the chart's unset default is correct.
#   REDIS_USER — the chart renders it only when the operator sets it, and the
#     module creates no ElastiCache RBAC user. The implicit ElastiCache account
#     is "default", but nothing in this repository configures RBAC.
#     # CONFIRMAR no chart: whether the plugin needs REDIS_USER at all against an
#     # auth-token (non-RBAC) ElastiCache. Not emitted until confirmed.
################################################################################

output "helm_values" {
  description = "plugin-br-bank-transfer chart env vars this datastore fills in, ready to merge into bankTransfer.configmap. Pair it with valkey.enabled = false AND valkey.external = true so the bundled Bitnami subchart is neither deployed nor consulted for credentials."
  value = {
    REDIS_HOST = local.redis_host_port
    REDIS_DB   = tostring(var.redis_db_index)
    REDIS_TLS  = local.redis_tls_required ? "true" : "false"

    # Only rendered when MULTI_TENANT_ENABLED is "true". Emitted regardless so
    # enabling multi-tenancy needs no second lookup; harmless when it is off.
    # Note the shape flip: this pair is SPLIT while REDIS_HOST above is not.
    MULTI_TENANT_REDIS_HOST = module.valkey.endpoint
    MULTI_TENANT_REDIS_PORT = tostring(module.valkey.port)
    MULTI_TENANT_REDIS_TLS  = local.redis_tls_required ? "true" : "false"
  }
}
