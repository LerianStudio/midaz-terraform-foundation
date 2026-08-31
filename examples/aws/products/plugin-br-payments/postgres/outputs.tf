################################################################################
# Outputs
#
# The seven uniform contract names (mode, endpoint, port, security_group_id,
# secret_arn, secret_name, identifier) are passed straight through from the
# module, unchanged, so every products/*/* root answers `terraform output` the
# same way regardless of which datastore it wraps.
#
# There is no dns_name output and no private zone: the RDS certificate covers
# *.{region}.rds.amazonaws.com, so a CNAME in front of it breaks TLS hostname
# verification — which matters more here than anywhere else, because this chart
# ships POSTGRES_SSLMODE = "require" by default.
#
# The module is NOT under count here — this root stack wraps exactly one
# datastore — so a plain module.postgres.x reference is safe.
################################################################################

locals {
  ################################################################################
  # The read replica block is emitted ONLY when a replica exists.
  #
  # The application resolves "replica DSN or primary" when POSTGRES_REPLICA_HOST
  # is empty, so an absent replica needs no variables at all. It also validates
  # conditionally: as soon as ANY POSTGRES_REPLICA_* value is present,
  # POSTGRES_REPLICA_HOST becomes mandatory. Emitting a half-filled block or
  # pointing the block at the primary would therefore be worse than emitting
  # nothing — this is the one place where this product deliberately does NOT
  # follow the midaz shape.
  #
  # replica_endpoint is null both when no replica was created and in shared mode
  # (a shared read replica, if any, belongs to products/shared-resources/postgres),
  # so the condition covers both.
  ################################################################################
  helm_replica_values = module.postgres.replica_endpoint == null ? {} : {
    POSTGRES_REPLICA_HOST = module.postgres.replica_endpoint
    POSTGRES_REPLICA_PORT = tostring(module.postgres.port)
    POSTGRES_REPLICA_USER = module.postgres.username
    POSTGRES_REPLICA_DB   = module.postgres.database_name
  }
}

################################################################################
# Cross-stack context (assert the derived strings without opening the tfvars)
################################################################################

output "vpc_name" {
  description = "tag:Name of the VPC the instance was placed in, as derived or overridden. Should equal the vpc_name output of infra-base/vpc."
  value       = module.network.vpc_name
}

output "eks_cluster_name" {
  description = "EKS cluster whose node security group was looked up. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to plugin-br-payments."
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
  description = "Raw AWS hostname of the instance — the POSTGRES_HOST the Helm release connects to. In shared mode this is the hostname of shared-{env}-postgres, resolved by name."
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
  description = "ARN of the Secrets Manager secret holding the master credentials: plugin-br-payments-{env}-postgres/password in dedicated mode, shared-{env}-postgres/password in shared mode."
  value       = module.postgres.secret_arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret holding the master credentials. This is the value an External Secrets Operator ExternalSecret references to populate the chart's app.secrets.POSTGRES_PASSWORD key."
  value       = module.postgres.secret_name
}

output "identifier" {
  description = "RDS DB instance identifier: plugin-br-payments-{environment}-postgres in dedicated mode, the resolved shared-{env}-postgres in shared mode."
  value       = module.postgres.identifier
}

################################################################################
# PostgreSQL specifics
################################################################################

output "database_name" {
  description = "Name of the initial database RDS created, emitted as the chart's POSTGRES_DB. plugin-br-payments runs a single logical database, so unlike midaz this value is a fact Terraform owns rather than something the application migration invents."
  value       = module.postgres.database_name
}

output "username" {
  description = "Master username. Emitted as POSTGRES_USER, and also the DB_USER_ADMIN the chart's optional bootstrap Job (global.externalPostgresDefinitions) expects when it creates the least-privilege plugin_br_payments role."
  value       = module.postgres.username
}

output "replica_endpoint" {
  description = "Raw AWS hostname of the read replica. Null when no replica was created, and null in shared mode. When null, helm_values omits the whole POSTGRES_REPLICA_* block on purpose — the application falls back to the primary by itself."
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
# The exact env var names the plugin-br-payments chart reads, so wiring the
# release is a copy, not a translation. Verified against chart
# plugin-br-payments-helm 1.1.0 (appVersion 1.0.0-beta.9), values.yaml:199-208
# (app.configmap) rendered by templates/configmap.yaml, and values.yaml:280
# (app.secrets) rendered by templates/secrets.yaml.
#
# THIS CHART USES THE POSTGRES_* FAMILY, not midaz's DB_*. Its sibling
# plugin-br-pix-direct-jd uses a third spelling (DATABASE_*). There is no
# Lerian-wide PostgreSQL variable convention; each chart was read separately.
#
# These keys land in .Values.app.configmap. Merge accordingly:
#
#   app:
#     configmap:
#       POSTGRES_HOST: ...
#
# NOT emitted here, on purpose:
#   POSTGRES_PASSWORD — read from secret_name by External Secrets, never an
#     output. Note templates/deployment.yaml prefers the postgresql SUBCHART
#     secret whenever the subchart is enabled and not external, so
#     postgresql.enabled=false + postgresql.external=true has to be set or the
#     credentials Terraform wrote are silently ignored.
#   POSTGRES_SSLMODE — a client policy decision, not an infrastructure fact. The
#     chart already ships "require", which RDS satisfies on every instance, and
#     that chart value is load-bearing: the binary's own compiled default is
#     "disable", so dropping the chart key silently downgrades the connection.
#     Leave it at the chart default; do not let Terraform own it.
#   POSTGRES_MAX_IDLE_CONNS / _MAX_OPEN_CONNS / _CONN_MAX_LIFETIME_MINS /
#     _CONN_MAX_IDLE_TIME_MINS / _CONNECT_TIMEOUT_SEC — client pool tuning.
#     They should track instance_class, but the mapping is a workload decision
#     and Terraform has no honest value for it.
#   POSTGRES_REPLICA_PASSWORD — same secret as the primary (a read replica
#     inherits the master credentials), so External Secrets should populate it
#     from the same secret_name when a replica is in use.
################################################################################

output "helm_values" {
  description = "plugin-br-payments chart env vars this datastore fills in, ready to merge into .Values.app.configmap. Pair it with postgresql.enabled = false and postgresql.external = true so the bundled Bitnami subchart is not deployed alongside RDS AND the password is read from the chart's own Secret. The POSTGRES_REPLICA_* keys appear only when create_read_replica produced one."
  value = merge({
    POSTGRES_HOST = module.postgres.endpoint
    POSTGRES_PORT = tostring(module.postgres.port)
    POSTGRES_USER = module.postgres.username
    POSTGRES_DB   = module.postgres.database_name
  }, local.helm_replica_values)
}
