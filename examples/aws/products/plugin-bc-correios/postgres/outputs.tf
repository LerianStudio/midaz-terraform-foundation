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
# instance — so a plain module.postgres.x reference is safe. The
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
  description = "tag:Name of the VPC the instance was placed in, as derived or overridden. Should equal the vpc_name output of infra-base/vpc."
  value       = module.network.vpc_name
}

output "eks_cluster_name" {
  description = "EKS cluster whose node security group was looked up. Should equal the cluster_name output of infra-base/eks. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to plugin-bc-correios."
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
  description = "Security group protecting the instance. Null in shared mode — ingress on the shared one is owned by products/shared-resources/postgres."
  value       = module.postgres.security_group_id
}

output "secret_arn" {
  description = "ARN of the Secrets Manager secret holding the master credentials: plugin-bc-correios-{env}-postgres/password in dedicated mode, shared-{env}-postgres/password in shared mode."
  value       = module.postgres.secret_arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret holding the master credentials. This is the value an External Secrets Operator ExternalSecret references to populate POSTGRES_PASSWORD."
  value       = module.postgres.secret_name
}

output "identifier" {
  description = "RDS DB instance identifier: plugin-bc-correios-{environment}-postgres in dedicated mode, the resolved shared-{env}-postgres in shared mode."
  value       = module.postgres.identifier
}

################################################################################
# PostgreSQL specifics
################################################################################

output "database_name" {
  description = "Name of the initial database RDS created. Emitted as POSTGRES_NAME."
  value       = module.postgres.database_name
}

output "username" {
  description = "Master username. Emitted as POSTGRES_USER."
  value       = module.postgres.username
}

output "replica_endpoint" {
  description = "Raw AWS hostname of the read replica. Null when no replica was created, and null in shared mode. The plugin-bc-correios-helm chart has no read-only PostgreSQL variable, so this is published for operators rather than consumed by the release."
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
# Verified against plugin-bc-correios-helm 2.2.0 (appVersion 1.2.0),
# templates/configmap.yaml (the PostgreSQL block) and templates/secrets.yaml,
# both keyed off the "bc-correios" values block.
#
# THE VARIABLE NAMES ARE POSTGRES_*, NOT DB_*. midaz uses DB_ONBOARDING_HOST /
# DB_TRANSACTION_HOST; this chart uses a single POSTGRES_HOST. Nothing about the
# midaz PostgreSQL mapping transfers.
#
# TWO CHART DEFAULTS ARE ILLEGAL ON RDS AND MUST BE OVERRIDDEN BY THESE VALUES:
#
#   POSTGRES_NAME  chart default "plugin-bc-correios"
#   POSTGRES_USER  chart default "plugin-bc-correios"
#
# RDS restricts both db_name and the master username to letters, digits and
# underscores, starting with a letter. CreateDBInstance rejects the hyphens
# outright — this is an apply-time API error, not a warning — which is why
# var.database_name and var.username default to the underscored form and why the
# root validates them. Leaving the chart defaults in place produces an
# application pointed at a database that does not exist.
#
# POSTGRES_SSLMODE IS EMITTED, and it is the one client-policy key this root does
# take a position on. The chart default is "disable"; RDS presents a certificate
# on every instance, so "require" costs nothing and encrypts the connection.
# "require" and not "verify-full" on purpose: verify-full needs the global RDS CA
# bundle mounted in the pod, which Terraform does not distribute. Upgrade to
# verify-full once the chart mounts a CA.
#
# NOT emitted here, on purpose:
#   POSTGRES_PASSWORD  — read from secret_name by External Secrets. With
#     postgresql.enabled = false and postgresql.external = true the chart stops
#     reading the bundled subchart Secret and takes this key from its own Secret,
#     so the ExternalSecret has to fill it before the first release.
#   POSTGRES_MAX_CONNS / POSTGRES_MIN_CONNS — application pool tuning (chart
#     defaults 50 and 5). Worth revisiting against the instance class: a
#     db.t4g.micro does not have 50 connections to spare, but that is a chart
#     decision, not an infrastructure fact.
################################################################################

output "helm_values" {
  description = "plugin-bc-correios chart env vars this datastore fills in, ready to merge into the bc-correios.configmap block. Pair it with postgresql.enabled = false and postgresql.external = true so the bundled Bitnami subchart is not deployed alongside RDS. Note POSTGRES_NAME and POSTGRES_USER OVERRIDE the chart defaults, which RDS rejects — see the header."
  value = {
    POSTGRES_HOST    = module.postgres.endpoint
    POSTGRES_PORT    = tostring(module.postgres.port)
    POSTGRES_USER    = module.postgres.username
    POSTGRES_NAME    = module.postgres.database_name
    POSTGRES_SSLMODE = "require"
  }
}
