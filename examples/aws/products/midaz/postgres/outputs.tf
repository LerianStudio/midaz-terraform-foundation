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

locals {
  # Without a read replica the chart still needs the REPLICA_* variables set,
  # because the ledger opens a second connection pool from them. Pointing them at
  # the primary is what a single-instance deployment does; the chart's own
  # default ("midaz-postgresql-replication") is a subchart service that stops
  # existing the moment postgresql.enabled is false.
  #
  # replica_endpoint is null both when no replica was created and in shared mode
  # (a shared read replica, if any, belongs to products/shared-resources/postgres), so
  # the fallback covers both.
  helm_replica_host = coalesce(module.postgres.replica_endpoint, module.postgres.endpoint)
}

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
  description = "EKS cluster whose node security group was looked up. Should equal the cluster_name output of infra-base/eks. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to midaz."
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
  description = "ARN of the Secrets Manager secret holding the master credentials: midaz-{env}-postgres/password in dedicated mode, shared-{env}-postgres/password in shared mode."
  value       = module.postgres.secret_arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret holding the master credentials. This is the value an External Secrets Operator ExternalSecret references to populate DB_ONBOARDING_PASSWORD and DB_TRANSACTION_PASSWORD."
  value       = module.postgres.secret_name
}

output "identifier" {
  description = "RDS DB instance identifier: midaz-{environment}-postgres in dedicated mode, the resolved shared-{env}-postgres in shared mode."
  value       = module.postgres.identifier
}

################################################################################
# PostgreSQL specifics
################################################################################

output "database_name" {
  description = "Name of the INITIAL database RDS created. midaz runs two logical databases on the instance (onboarding and transaction); RDS creates one at provisioning time, so the second is created by the application migration and neither DB_ONBOARDING_NAME nor DB_TRANSACTION_NAME is emitted from here."
  value       = module.postgres.database_name
}

output "username" {
  description = "Master username. Feeds DB_ONBOARDING_USER / DB_TRANSACTION_USER unless the chart is given per-database roles created outside Terraform."
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
# The exact env var names the midaz chart reads, so wiring the release is a copy,
# not a translation. Verified against chart 8.7.0 (appVersion 3.8.0),
# templates/ledger/configmap.yaml.
#
# Everything below lands on the LEDGER deployment. There is no separate
# onboarding and transaction deployment — the ledger container is unified and
# carries both sets of variables, pointed at the same instance.
#
# Values are strings because they end up in a ConfigMap, which has no other type.
#
# NOT emitted here, on purpose:
#   DB_ONBOARDING_NAME / DB_TRANSACTION_NAME — the chart defaults are
#     "onboarding" and "transaction"; RDS creates a single initial database and
#     the second is created by the application migration, so Terraform does not
#     know these and must not guess them.
#   DB_*_PASSWORD — read from secret_name by External Secrets, never an output.
#   DB_*_SSLMODE  — a client policy decision, not an infrastructure fact. RDS
#     accepts TLS on every instance; the chart default is "disable".
################################################################################

output "helm_values" {
  description = "midaz chart env vars this datastore fills in, ready to merge into ledger.configmap. Pair it with postgresql.enabled = false (and postgresql.external = true) so the bundled Bitnami subchart is not deployed alongside RDS."
  value = {
    DB_ONBOARDING_HOST  = module.postgres.endpoint
    DB_ONBOARDING_PORT  = tostring(module.postgres.port)
    DB_ONBOARDING_USER  = module.postgres.username
    DB_TRANSACTION_HOST = module.postgres.endpoint
    DB_TRANSACTION_PORT = tostring(module.postgres.port)
    DB_TRANSACTION_USER = module.postgres.username

    DB_ONBOARDING_REPLICA_HOST  = local.helm_replica_host
    DB_ONBOARDING_REPLICA_PORT  = tostring(module.postgres.port)
    DB_ONBOARDING_REPLICA_USER  = module.postgres.username
    DB_TRANSACTION_REPLICA_HOST = local.helm_replica_host
    DB_TRANSACTION_REPLICA_PORT = tostring(module.postgres.port)
    DB_TRANSACTION_REPLICA_USER = module.postgres.username
  }
}
