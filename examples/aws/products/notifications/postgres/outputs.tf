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
  description = "EKS cluster whose node security group was looked up. Should equal the cluster_name output of infra-base/eks. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to notifications."
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
  description = "ARN of the Secrets Manager secret holding the master credentials: notifications-{env}-postgres/password in dedicated mode, shared-{env}-postgres/password in shared mode."
  value       = module.postgres.secret_arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret holding the master credentials. This is the value an External Secrets Operator ExternalSecret references."
  value       = module.postgres.secret_name
}

output "identifier" {
  description = "RDS DB instance identifier: notifications-{environment}-postgres in dedicated mode, the resolved shared-{env}-postgres in shared mode."
  value       = module.postgres.identifier
}

################################################################################
# PostgreSQL specifics
################################################################################

output "database_name" {
  description = "Name of the initial database RDS created, emitted as POSTGRES_NAME. notifications runs one logical database, so this is the complete answer — there is no second database created by a migration the way midaz has."
  value       = module.postgres.database_name
}

output "username" {
  description = "Master username. Feeds POSTGRES_USER."
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
  # This is the opposite of the midaz root, which coalesces the replica host back
  # to the primary. The reason is the chart: notifications ships every
  # POSTGRES_REPLICA_* key as an EMPTY STRING default (values.yaml `secrets`),
  # and the service treats "empty" as "no replica, use the primary pool". Filling
  # them with the primary's own address would move the read pool onto the writer
  # while telling the operator a replica is configured. Empty is both honest and
  # the behaviour they want.
  #
  # replica_endpoint is null when no replica was created AND in shared mode (a
  # shared read replica, if any, belongs to products/shared-resources/postgres),
  # so the single check covers both.
  ################################################################################
  has_replica = module.postgres.replica_endpoint != null

  replica_values = local.has_replica ? {
    POSTGRES_REPLICA_HOST = module.postgres.replica_endpoint
    POSTGRES_REPLICA_PORT = tostring(module.postgres.port)
    POSTGRES_REPLICA_USER = module.postgres.username
    POSTGRES_REPLICA_NAME = module.postgres.database_name
  } : {}
}

################################################################################
# Helm handoff
#
# The exact env var names the notifications chart reads, so wiring the release is
# a copy, not a translation. Verified against chart 1.0.0-beta.4 (appVersion
# 0.1.0), values.yaml `config` / `secrets` and templates/configmap.yaml.
#
# There is ONE ConfigMap and ONE Secret for the whole release. api, worker-email,
# worker-sms and worker-webhook all mount both with envFrom and add nothing but
# WORKER_HEALTH_ADDRESS, so — unlike a per-component chart — there is exactly one
# place for each value below.
#
# THE CHART HAS NO BUNDLED SUBCHARTS. notifications/Chart.yaml declares no
# dependencies at all and says so out loud: "No dependencies: Postgres, Redis and
# RabbitMQ are external". There is therefore no postgresql.enabled to switch off,
# which is a real difference from midaz and from the two plugin charts.
#
# NOT emitted here, on purpose:
#   POSTGRES_PASSWORD — read from secret_name by External Secrets, never an
#     output.
#   POSTGRES_REPLICA_PASSWORD — same.
#   POSTGRES_SSLMODE — a client policy decision, not an infrastructure fact. The
#     chart default is already "require", which every RDS instance accepts, so
#     leaving it alone is correct. (Note the chart default differs from midaz's
#     "disable"; do not copy midaz's here.)
#   DATABASE_URL — the pre-built DSN the golang-migrate Job consumes. It embeds
#     the URL-escaped password, so Terraform must not build it: it would land in
#     state and in `terraform output` in cleartext. Assemble it in the secret
#     store (or via the ArgoCD Vault Plugin) from secret_name plus the host,
#     port, user and database published here. Shape, from the chart's own
#     comment: postgres://USER:URLENCODED_PW@HOST:PORT/DB?sslmode=require
################################################################################

output "helm_values" {
  description = "notifications chart env vars this datastore fills in, ready to merge into .Values.config (the shared ConfigMap). The chart bundles no PostgreSQL subchart, so there is nothing to disable alongside RDS."
  value = {
    POSTGRES_HOST = module.postgres.endpoint
    POSTGRES_PORT = tostring(module.postgres.port)
    POSTGRES_USER = module.postgres.username
    POSTGRES_NAME = module.postgres.database_name
  }
}

output "helm_secret_values" {
  description = "The same handoff, for the keys the notifications chart routes through .Values.secrets (the Secret) instead of .Values.config. Nothing in this map is sensitive — POSTGRES_REPLICA_HOST/PORT/USER/NAME are addresses and identifiers — but the chart reads them from the Secret, so they have to be written there. Empty when no read replica exists, which is exactly what the chart's empty-string defaults mean."
  value       = local.replica_values
}
