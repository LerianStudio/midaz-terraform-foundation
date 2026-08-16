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
# datastore — so a plain module.postgres.x reference is safe.
################################################################################

################################################################################
# Cross-stack context (assert the derived strings without opening the tfvars)
################################################################################

output "vpc_name" {
  description = "tag:Name of the VPC the instance was placed in, as derived or overridden. Should equal the vpc_name output of infra-base/vpc."
  value       = module.network.vpc_name
}

output "eks_cluster_name" {
  description = "EKS cluster whose node security group was looked up. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to br-consignado-gw."
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
  description = "ARN of the Secrets Manager secret holding the master credentials: br-consignado-gw-{env}-postgres/password in dedicated mode, shared-{env}-postgres/password in shared mode."
  value       = module.postgres.secret_arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret holding the master credentials. This is the value an External Secrets Operator ExternalSecret references to populate api.secrets.POSTGRES_PASSWORD (values.yaml:64). The migrations Job takes the same password either inline at migrations.postgres.password or by reference at migrations.postgres.passwordSecret (values.yaml:159-162)."
  value       = module.postgres.secret_name
}

output "identifier" {
  description = "RDS DB instance identifier: br-consignado-gw-{environment}-postgres in dedicated mode, the resolved shared-{env}-postgres in shared mode."
  value       = module.postgres.identifier
}

################################################################################
# PostgreSQL specifics
################################################################################

output "database_name" {
  description = "Name of the initial database RDS created, emitted to the chart as POSTGRES_NAME. The chart ships no default for it (values.yaml:59 is an empty string), so this value is authoritative rather than a mirror."
  value       = module.postgres.database_name
}

output "username" {
  description = "Master username of the instance, emitted as POSTGRES_USER. The chart ships no default for it either (values.yaml:58 is empty), so nothing contradicts the master user here."
  value       = module.postgres.username
}

output "replica_endpoint" {
  description = "Raw AWS hostname of the read replica. Null when no replica was created, and null in shared mode. The chart has no reader variable, so nothing consumes this."
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
# Verified against chart br-consignado-gw-helm 1.0.0 (appVersion
# 1.3.0-beta.36), values.yaml lines 56-60 and templates/api-configmap.yaml
# lines 10-11.
#
# THE VARIABLE FAMILY IS POSTGRES_*, NOT DB_*. This product names its
# connection variables POSTGRES_HOST / POSTGRES_PORT / POSTGRES_USER /
# POSTGRES_NAME / POSTGRES_SSLMODE. midaz uses DB_ONBOARDING_* / DB_TRANSACTION_*,
# tracer and plugin-access-manager use a short DB_* family. There is no
# Lerian-wide convention here; the chart is the only authority.
#
# Note also POSTGRES_NAME, not POSTGRES_DB or POSTGRES_DATABASE.
#
# Everything below lands on `api.configmap`, which templates/api-configmap.yaml
# dumps verbatim into a ConfigMap consumed with envFrom by the api Deployment
# (templates/api-deployment.yaml:40-42). There is no allowlist in that template
# — whatever is put in the map becomes an env var, so a typo becomes a silently
# ignored variable rather than a render error.
#
# THE MIGRATIONS JOB INHERITS THIS. templates/migrations-job.yaml:4-8 resolves
# its own host/port/user/database/sslMode from `migrations.postgres.*` and falls
# back to the api.configmap values above, so setting api.configmap alone is
# enough for both. Override migrations.postgres.* only to point the migration at
# a different instance or a more privileged role. One difference worth knowing:
# the Job defaults sslMode to "disable" when both are empty
# (templates/migrations-job.yaml:8), while values.yaml:60 leaves the api's
# POSTGRES_SSLMODE as an empty string.
#
# Values are strings because they end up in a ConfigMap.
#
# NOT emitted here, on purpose:
#   POSTGRES_PASSWORD — read from secret_name by External Secrets, never an
#     output. It is api.secrets.POSTGRES_PASSWORD (values.yaml:64).
#   POSTGRES_SSLMODE  — a client policy decision, not an infrastructure fact,
#     and the same call the midaz root makes about its DB_*_SSLMODE. RDS accepts
#     TLS on every instance whatever the client asks for.
################################################################################

output "helm_values" {
  description = "br-consignado-gw chart env vars this datastore fills in, ready to merge into api.configmap. The chart declares NO subcharts at all (Chart.yaml has no dependencies block; README.md:13: \"The chart deliberately has no infra subcharts\"), so there is no postgresql.enabled to turn off — the chart has always expected an external instance."
  value = {
    POSTGRES_HOST = module.postgres.endpoint
    POSTGRES_PORT = tostring(module.postgres.port)
    POSTGRES_USER = module.postgres.username
    POSTGRES_NAME = module.postgres.database_name
  }
}
