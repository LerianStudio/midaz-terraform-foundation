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
# datastore — so a plain module.postgres.x reference is safe. The one(...)
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
  description = "tag:Name of the VPC the instance was placed in, as derived or overridden. Should equal the vpc_name output of infra-base/vpc."
  value       = module.network.vpc_name
}

output "eks_cluster_name" {
  description = "EKS cluster whose node security group was looked up. Should equal the cluster_name output of infra-base/eks. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to plugin-br-bank-transfer."
  value       = module.network.eks_cluster_name
}

output "ingress_security_group_ids" {
  description = "Security groups authorised on the instance. Empty before infra-base/eks exists unless allowed_security_group_ids was passed explicitly."
  value       = module.network.ingress_security_group_ids
}

output "ingress_cidr_blocks" {
  description = "CIDR blocks authorised on the instance. Holds the Type=private subnet CIDRs while allow_private_subnet_cidr_ingress is true."
  value       = module.network.ingress_cidr_blocks
}

################################################################################
# Uniform datastore contract
################################################################################

output "mode" {
  description = "Provisioning mode this stack ran in: dedicated or shared."
  value       = module.postgres.mode
}

output "endpoint" {
  description = "Raw AWS hostname of the instance — the database host the Helm release connects to. In shared mode this is the hostname of shared-{env}-postgres, resolved by name."
  value       = module.postgres.endpoint
}

output "port" {
  description = "PostgreSQL port."
  value       = module.postgres.port
}

output "security_group_id" {
  description = "Security group protecting the instance. Null in shared mode — ingress on the shared instance is owned by products/shared-resources/postgres."
  value       = module.postgres.security_group_id
}

output "secret_arn" {
  description = "ARN of the Secrets Manager secret holding the master credentials: plugin-br-bank-transfer-{env}-postgres/password in dedicated mode, shared-{env}-postgres/password in shared mode."
  value       = module.postgres.secret_arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret holding the master credentials. This is the value an External Secrets Operator ExternalSecret references."
  value       = module.postgres.secret_name
}

output "identifier" {
  description = "RDS DB instance identifier: plugin-br-bank-transfer-{environment}-postgres in dedicated mode, the resolved shared-{env}-postgres in shared mode."
  value       = module.postgres.identifier
}

################################################################################
# PostgreSQL specifics
################################################################################

output "database_name" {
  description = "Name of the initial database RDS created, emitted as POSTGRES_DB. The plugin runs one logical database, so this is the complete answer."
  value       = module.postgres.database_name
}

output "username" {
  description = "Master username. Feeds POSTGRES_USER (and POSTGRES_REPLICA_USER when a replica exists)."
  value       = module.postgres.username
}

output "replica_endpoint" {
  description = "Raw AWS hostname of the read replica. Null when no replica was created, and null in shared mode."
  value       = module.postgres.replica_endpoint
}

output "replica_identifier" {
  description = "RDS DB instance identifier of the read replica. Null when no replica was created."
  value       = module.postgres.replica_identifier
}

output "subnet_group_name" {
  description = "Name of the DB subnet group. Null in shared mode."
  value       = module.postgres.subnet_group_name
}

locals {
  ################################################################################
  # The replica block is emitted ONLY when a replica actually exists.
  #
  # This mirrors the chart rather than the midaz root. templates/configmap.yaml
  # wraps the whole POSTGRES_REPLICA_* block in
  #
  #     {{- if .Values.bankTransfer.configmap.POSTGRES_REPLICA_HOST }}
  #
  # so an unset host means "no CQRS read pool", which is the correct shape for a
  # single-instance deployment. midaz instead coalesces its replica host back to
  # the primary, because its chart defaults those variables to a subchart Service
  # that disappears when the subchart is off. This chart has no such trap.
  #
  # replica_endpoint is null when no replica was created AND in shared mode (a
  # shared read replica, if any, belongs to products/shared-resources/postgres),
  # so the single check covers both.
  ################################################################################
  replica_values = module.postgres.replica_endpoint != null ? {
    POSTGRES_REPLICA_HOST = module.postgres.replica_endpoint
    POSTGRES_REPLICA_PORT = tostring(module.postgres.port)
    POSTGRES_REPLICA_USER = module.postgres.username
    POSTGRES_REPLICA_DB   = module.postgres.database_name
  } : {}
}

################################################################################
# Helm handoff
#
# The exact env var names the plugin-br-bank-transfer chart reads, so wiring the
# release is a copy, not a translation. Verified against chart 1.5.0 (appVersion
# 1.2.1), templates/configmap.yaml and values.yaml (bankTransfer.configmap).
#
# All of it lands on ONE ConfigMap, bankTransfer.configmap. The chart is
# lerian.studio/chart-type: single-service — one Deployment, one ConfigMap, one
# Secret, both mounted with envFrom.
#
# THE WHOLE POSTGRES BLOCK IS SINGLE-TENANT ONLY. templates/configmap.yaml wraps
# it in {{- if not $multiTenantEnabled }}: with MULTI_TENANT_ENABLED = "true" the
# chart renders NO POSTGRES_* keys at all and the plugin resolves per-tenant
# databases through the tenant-manager instead. Merging this map into a
# multi-tenant release is harmless but has no effect — the keys are simply not
# read. See the product README.
#
# PAIR IT WITH BOTH SUBCHART SWITCHES:
#     postgresql:
#       enabled:  false
#       external: true
# `enabled: false` stops the Bitnami subchart from deploying; `external: true` is
# what moves password resolution off the subchart Secret and onto the chart's
# own, so the credential Terraform wrote is the one actually used. Setting only
# the first leaves the deployment reading a Secret that no longer exists.
#
# NOT emitted here, on purpose:
#   POSTGRES_PASSWORD / POSTGRES_REPLICA_PASSWORD — read from secret_name by
#     External Secrets, never an output. Note that the chart ALSO requires
#     bankTransfer.secrets.POSTGRES_PASSWORD to be non-empty when migrations run
#     against an external PostgreSQL: helper "bank-transfer.migrationPostgresPassword"
#     calls required() on it and the render fails otherwise.
#   POSTGRES_SSLMODE — a client policy decision, not an infrastructure fact. The
#     chart default is already "require", which every RDS instance accepts.
#   MIGRATIONS_PATH and the pool-tuning keys — application configuration.
################################################################################

output "helm_values" {
  description = "plugin-br-bank-transfer chart env vars this datastore fills in, ready to merge into bankTransfer.configmap. Pair it with postgresql.enabled = false AND postgresql.external = true so the bundled Bitnami subchart is neither deployed nor consulted for credentials. Empty of replica keys unless create_read_replica is true."
  value = merge({
    POSTGRES_HOST = module.postgres.endpoint
    POSTGRES_PORT = tostring(module.postgres.port)
    POSTGRES_USER = module.postgres.username
    POSTGRES_DB   = module.postgres.database_name
  }, local.replica_values)
}
