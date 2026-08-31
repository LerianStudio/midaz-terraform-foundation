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
# DB_*_REPLICA_HOST and the ledger opens a second connection pool from it. The
# br-sfn chart defines no replica variable on any rail — component configmaps are
# emitted verbatim, so a replica host would be an operator-supplied key this
# stack cannot name.
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
  description = "EKS cluster whose node security group was looked up. Should equal the cluster_name output of infra-base/eks. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to br-sfn."
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
  description = "ARN of the Secrets Manager secret holding the master credentials: br-sfn-{env}-postgres/password in dedicated mode, shared-{env}-postgres/password in shared mode."
  value       = module.postgres.secret_arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret holding the master credentials. This is the value an External Secrets Operator ExternalSecret references to populate each enabled rail's POSTGRES_PASSWORD. Read the URL-safety warning in README.md first: the baked-flavour migration Jobs interpolate it into a postgres:// DSN unescaped."
  value       = module.postgres.secret_name
}

output "identifier" {
  description = "RDS DB instance identifier: br-sfn-{environment}-postgres in dedicated mode, the resolved shared-{env}-postgres in shared mode."
  value       = module.postgres.identifier
}

################################################################################
# PostgreSQL specifics
################################################################################

output "database_name" {
  description = "Name of the INITIAL database RDS created — the bootstrap database, NOT a rail database. Each br-sfn rail reads its own name from its own component configmap (POSTGRES_DB for spb/spi/siloc/scr/desk, POSTGRES_NAME for correios) and RDS creates exactly one at provisioning time, so the rail databases are created on the instance outside Terraform. It is therefore NOT emitted into helm_values."
  value       = module.postgres.database_name
}

output "username" {
  description = "Master username of the instance. Each rail's migration Job connects as its component's POSTGRES_USER, which nothing in the chart creates; this master user is what bootstraps the rest."
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
# Verified against br-sfn chart 1.1.0 (appVersion 1.0.0-beta.1).
#
# THIS CHART HAS NO FIXED ENV ALLOWLIST. <component>.configmap and
# <component>.secrets are emitted VERBATIM into each component's ConfigMap and
# Secret (README.md:66-72), so the chart itself only *names* the variables its own
# templates read. For Postgres that set IS named and IS enforced, by the shared
# migration helper:
#
#   templates/_helpers.tpl:474-490   POSTGRES_HOST, POSTGRES_PORT, POSTGRES_USER,
#                                    POSTGRES_DB (dbCfgKey), POSTGRES_SSLMODE,
#                                    POSTGRES_PASSWORD — host, user and database
#                                    are REQUIRED and the render FAILS LOUD when
#                                    missing
#   templates/correios/migrations-job.yaml:3
#                                    correios overrides dbCfgKey to POSTGRES_NAME
#   values-template.yaml:10-78       the same keys, per rail
#
# THE KEYS BELOW ARE PER-COMPONENT, NOT GLOBAL. There is no chart-wide configmap.
# Merge this map into EVERY rail that owns a schema — spb, spi, siloc, scr, desk,
# correios — under that component's own `configmap:` block. The four SPI
# components (api, dict, brcode, core) share spi.configmap, so SPI takes it once.
#
# NOT emitted here, on purpose:
#   POSTGRES_DB / POSTGRES_NAME — br-sfn is a MONOREPO OF RAILS and each rail owns
#     its own database on the instance. RDS creates ONE at provisioning time
#     (database_name, the bootstrap database); the rail databases are created on
#     the instance outside Terraform, so Terraform does not know them and must not
#     guess. Note the split: correios reads POSTGRES_NAME, every other rail reads
#     POSTGRES_DB (templates/_helpers.tpl:483, README.md:60-63).
#   POSTGRES_PASSWORD — read from secret_name by External Secrets, never an
#     output. READ THE URL-SAFE WARNING IN README.md BEFORE THE FIRST APPLY.
#   POSTGRES_SSLMODE — a client policy decision, not an infrastructure fact. RDS
#     accepts TLS on every instance; the helper defaults it to "disable".
################################################################################

output "helm_values" {
  description = "br-sfn chart env vars this datastore fills in. PER-COMPONENT: merge into the `configmap:` block of every rail that owns a schema (spb, spi, siloc, scr, desk, correios), not into a chart-wide map — there is none. The rail database name is deliberately absent; see the header. This chart ships no Postgres subchart, so there is nothing to disable."
  value = {
    POSTGRES_HOST = module.postgres.endpoint
    POSTGRES_PORT = tostring(module.postgres.port)
    POSTGRES_USER = module.postgres.username
  }
}
