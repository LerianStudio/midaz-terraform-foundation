################################################################################
# Outputs
#
# The seven uniform contract names (mode, endpoint, port, security_group_id,
# secret_arn, secret_name, identifier) are passed straight through from the
# module, so an operator script reads this stack the same way regardless of
# which datastore it wraps.
#
# There is no dns_name output and no private zone: RDS presents a certificate
# for *.{region}.rds.amazonaws.com, so a CNAME in front of it breaks TLS
# hostname verification. `endpoint` is the raw AWS host.
#
# There is no `postgres_enabled` output any more. It existed when this tier was
# one root with five toggles; enablement is now "this directory was applied".
#
# The module is NOT under count here — this root wraps exactly one datastore —
# so a plain module.postgres.x reference is safe. The one(...) gymnastics live
# inside the module, where the count actually is.
#
# Products do NOT read this state with terraform_remote_state. They resolve the
# shared tier by NAME — data "aws_db_instance" on shared-{env}-postgres plus the
# Secrets Manager entry — which is what mode = "shared" does inside the module.
# These outputs exist for operators and to make the contract assertable with
# `terraform output`.
################################################################################

locals {
  # Without a read replica a consuming chart still needs its REPLICA_* variables
  # set, because the ledger opens a second connection pool from them. Pointing
  # them at the primary is what a single-instance deployment does.
  helm_replica_host = coalesce(module.postgres.replica_endpoint, module.postgres.endpoint)
}

################################################################################
# Cross-stack context (assert the derived strings without opening the tfvars)
#
# Re-exported from module.network, which owns the derivation. Note the "lerian"
# prefix on the VPC and the cluster: those are FOUNDATION names and keep it,
# while this datastore tier carries "shared".
################################################################################

output "vpc_name" {
  description = "tag:Name of the VPC the instance was placed in, as derived or overridden. Should equal the vpc_name output of infra-base/vpc."
  value       = module.network.vpc_name
}

output "eks_cluster_name" {
  description = "EKS cluster whose node security group was looked up. Should equal the cluster_name output of infra-base/eks. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to this tier."
  value       = module.network.eks_cluster_name
}

output "ingress_security_group_ids" {
  description = "Security groups authorised on the instance. Empty before infra-base/eks exists unless allowed_security_group_ids was passed explicitly. This is how you verify the EKS lookup resolved without reading a plan."
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
  description = "Provisioning mode the module ran in. Always \"dedicated\" here: this stack CREATES the shared instance. Products consume it with mode = \"shared\" — see the header of main.tf."
  value       = module.postgres.mode
}

output "endpoint" {
  description = "Raw AWS hostname of the shared instance — the DB host every consuming release connects to, in shared mode as well as from here."
  value       = module.postgres.endpoint
}

output "port" {
  description = "PostgreSQL port."
  value       = module.postgres.port
}

output "security_group_id" {
  description = "Security group protecting the shared instance. This stack owns its ingress; a product consuming with mode = \"shared\" gets null from its own module and cannot open anything itself."
  value       = module.postgres.security_group_id
}

output "secret_arn" {
  description = "ARN of shared-{environment}-postgres/password."
  value       = module.postgres.secret_arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret holding the master credentials. This is the exact name postgres-rds resolves in shared mode, and the value an External Secrets Operator ExternalSecret references."
  value       = module.postgres.secret_name
}

output "identifier" {
  description = "RDS DB instance identifier, shared-{environment}-postgres. This is the name a shared consumer resolves with data \"aws_db_instance\"."
  value       = module.postgres.identifier
}

################################################################################
# PostgreSQL specifics
################################################################################

output "database_name" {
  description = "Name of the INITIAL database RDS created on the shared instance. Each consuming product is expected to use its own schema or its own logical database, created outside Terraform."
  value       = module.postgres.database_name
}

output "username" {
  description = "Master username of the shared instance."
  value       = module.postgres.username
}

output "replica_endpoint" {
  description = "Raw AWS hostname of the read replica, shared-{env}-postgres-replica. Null when create_read_replica is false."
  value       = module.postgres.replica_endpoint
}

output "replica_identifier" {
  description = "RDS DB instance identifier of the read replica. Null when no replica was created."
  value       = module.postgres.replica_identifier
}

output "subnet_group_name" {
  description = "Name of the DB subnet group."
  value       = module.postgres.subnet_group_name
}

################################################################################
# Helm handoff
#
# SCOPE WARNING. These are the env var names of the midaz chart, verified
# against chart 8.7.0 (appVersion 3.8.0), templates/ledger/configmap.yaml. This
# tier is consumed by ANY product, and products/midaz/README.md is explicit that
# other Lerian charts must not be assumed to use the same names. The FACTS below
# — host, port, user — are tier-level and identical for every consumer; only the
# variable names are midaz's. A product on a different chart maps `endpoint`,
# `port` and `username` itself.
#
# NOT emitted here, on purpose:
#   DB_*_NAME     — RDS creates one initial database (var.database_name); each
#     product's logical database or schema is created outside Terraform, so this
#     stack does not know the names and must not guess them.
#   DB_*_PASSWORD — read from secret_name by External Secrets, never an output.
#   DB_*_SSLMODE  — a client policy decision, not an infrastructure fact.
################################################################################

output "helm_values" {
  description = "Chart env vars this datastore fills in (midaz naming — see the header), ready to merge into ledger.configmap. Pair it with postgresql.enabled = false and postgresql.external = true so the bundled Bitnami subchart is not deployed alongside RDS."
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
