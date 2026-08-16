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
# datastore — so a plain module.postgres.x reference is safe. The one(...)
# gymnastics live inside the module, where the count actually is.
################################################################################

################################################################################
# There is no helm_replica_host local here, unlike products/midaz/postgres.
#
# That local exists in the midaz root because the midaz chart defines
# DB_*_REPLICA_HOST and the ledger opens a second connection pool from it, so it
# has to be pointed somewhere even with no replica. The br-sisbajud chart defines
# NO replica variable at all — inventing one would be a guess, and pointing a
# non-existent variable at the primary would be a guess with a fallback.
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
  description = "EKS cluster whose node security group was looked up. Should equal the cluster_name output of infra-base/eks. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to br-sisbajud."
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
  description = "Raw AWS hostname of the instance — the DB_HOST the Helm release connects to. In shared mode this is the hostname of shared-{env}-postgres, resolved by name."
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
  description = "ARN of the Secrets Manager secret holding the master credentials: br-sisbajud-{env}-postgres/password in dedicated mode, shared-{env}-postgres/password in shared mode."
  value       = module.postgres.secret_arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret holding the master credentials. This is the value an External Secrets Operator ExternalSecret references to populate POSTGRES_PASSWORD, which the chart marks required for external Postgres and which the PreSync migration Job also reads by secretKeyRef."
  value       = module.postgres.secret_name
}

output "identifier" {
  description = "RDS DB instance identifier: br-sisbajud-{environment}-postgres in dedicated mode, the resolved shared-{env}-postgres in shared mode."
  value       = module.postgres.identifier
}

################################################################################
# PostgreSQL specifics
################################################################################

output "database_name" {
  description = "Name of the database RDS created — br_sisbajud, the value the chart carries as POSTGRES_NAME. br-sisbajud runs a single logical database, so unlike the midaz root this one DOES emit the name into helm_values."
  value       = module.postgres.database_name
}

output "username" {
  description = "Master username, br_sisbajud by default — the same value the chart carries as POSTGRES_USER, because nothing in the chart creates an application role."
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

################################################################################
# Helm handoff
#
# The exact env var names the br-sisbajud chart reads, so wiring the release is a
# copy, not a translation. Verified against chart 1.1.0 (appVersion
# 1.0.0-beta.109):
#
#   values-template.yaml:14-17   POSTGRES_HOST / POSTGRES_USER / POSTGRES_NAME /
#                                POSTGRES_SSLMODE, under brSisbajud.configmap
#   templates/configmap.yaml:10  POSTGRES_HOST is a RESERVED key the template
#                                writes itself; everything else in the map is
#                                emitted verbatim, so new keys need no chart change
#   templates/migrations/job.yaml:10-13
#                                the PreSync golang-migrate Job reads the SAME
#                                configmap keys as fallbacks, which is why the
#                                names below serve both the app and the migration
#
# DO NOT COPY THE midaz NAMES HERE. This chart has NO DB_* variables at all: no
# DB_ONBOARDING_*, no DB_TRANSACTION_*, no REPLICA pair. It is a single-service
# chart with one Go binary and one logical database.
#
# THE 1.0.1 RENAME. Chart 1.0 called these POSTGRES_DATABASE and
# POSTGRES_SSL_MODE; 1.0.1 renamed them to POSTGRES_NAME and POSTGRES_SSLMODE to
# match the lib-commons migrator (docs/UPGRADE-1.0.1.md:68,81). The old names are
# dead — anything still emitting them silently loses the database name.
#
# Values are strings because they end up in a ConfigMap, which has no other type.
#
# NOT emitted here, on purpose:
#   POSTGRES_PASSWORD — read from secret_name by External Secrets, never an
#     output. The chart marks it REQUIRED for external Postgres
#     (values-template.yaml:28) and the migration Job pulls it by secretKeyRef.
#   POSTGRES_SSLMODE — a client policy decision, not an infrastructure fact. RDS
#     accepts TLS on every instance; the chart default is "disable". Note that
#     lib-commons' migrator additionally refuses non-TLS Postgres unless
#     ALLOW_INSECURE_TLS is true — sslmode=disable alone is not enough
#     (templates/migrations/job.yaml:19-23).
#   POSTGRES_CONNECT_TIMEOUT_SEC — a client tunable; the chart defaults it to 10.
#
# The read replica is not wired: this chart has no replica variable. Set
# create_read_replica if an operator wants one, and read replica_endpoint
# directly — do not invent an env var for it.
################################################################################

output "helm_values" {
  description = "br-sisbajud chart env vars this datastore fills in, ready to merge into brSisbajud.configmap. Pair it with postgresql.enabled = false and postgresql.external = true so the bundled Bitnami subchart is not deployed alongside RDS. The same keys feed the PreSync migration Job through its configmap fallbacks, so migrations.postgres.* can stay empty."
  value = {
    POSTGRES_HOST = module.postgres.endpoint
    POSTGRES_PORT = tostring(module.postgres.port)
    POSTGRES_USER = module.postgres.username
    POSTGRES_NAME = module.postgres.database_name
  }
}
