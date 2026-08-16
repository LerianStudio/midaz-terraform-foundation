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
# verification for any client that validates it.
#
# There is no replica_endpoint / replica_identifier pair either, unlike
# products/midaz/postgres and products/plugin-br-payments/postgres: this stack
# creates no read replica because the chart defines no variable to point at one.
# See main.tf.
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
  description = "EKS cluster whose node security group was looked up. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to plugin-br-pix-direct-jd."
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
  description = "Raw AWS hostname of the instance — the DATABASE_HOST the Helm release connects to. In shared mode this is the hostname of shared-{env}-postgres, resolved by name."
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
  description = "ARN of the Secrets Manager secret holding the master credentials: plugin-br-pix-direct-jd-{env}-postgres/password in dedicated mode, shared-{env}-postgres/password in shared mode."
  value       = module.postgres.secret_arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret holding the master credentials. One secret feeds TWO chart keys: pix.secrets.DATABASE_PASSWORD and pix.secrets.POSTGRES_PASSWORD, which the deployment wires to the same value. The CronJob reads DATABASE_PASSWORD only."
  value       = module.postgres.secret_name
}

output "identifier" {
  description = "RDS DB instance identifier: plugin-br-pix-direct-jd-{environment}-postgres in dedicated mode, the resolved shared-{env}-postgres in shared mode."
  value       = module.postgres.identifier
}

################################################################################
# PostgreSQL specifics
################################################################################

output "database_name" {
  description = "Name of the initial database RDS created, emitted as DATABASE_NAME and POSTGRES_DB. This chart has no bootstrap Job, so RDS creating the database at provisioning time is what makes an external instance usable at all."
  value       = module.postgres.database_name
}

output "username" {
  description = "Master username, emitted as DATABASE_USER and POSTGRES_USER."
  value       = module.postgres.username
}

output "subnet_group_name" {
  description = "Name of the DB subnet group. Null in shared mode."
  value       = module.postgres.subnet_group_name
}

################################################################################
# Helm handoff
#
# The exact env var names the plugin-br-pix-direct-jd chart reads, so wiring the
# release is a copy, not a translation. Verified against chart
# plugin-br-pix-direct-jd-helm 3.0.0 (appVersion 1.2.1-beta.11),
# templates/plugin-br-pix-direct-jd/configmap.yaml lines 45-52 (the DATABASE_*
# family) and 90-93 (the POSTGRES_* compatibility trio).
#
# A THIRD SPELLING. midaz uses DB_*, plugin-br-payments uses POSTGRES_*, and this
# chart uses DATABASE_* for the real connection plus three POSTGRES_* keys the
# chart itself labels "for docker-compose compatibility". There is no
# Lerian-wide PostgreSQL variable convention.
#
# ALL OF THESE GO UNDER .Values.pix.configmap — INCLUDING THE CRONJOB'S.
# templates/plugin-br-pix-direct-jd-job/configmap.yaml lines 44-51 read
# .Values.pix.configmap.DATABASE_*, NOT .Values.job.configmap.*. The job.configmap
# DATABASE_* keys that exist in values.yaml are dead: setting them changes
# nothing. Merge this map into pix.configmap once and both workloads are wired.
#
#   pix:
#     configmap:
#       DATABASE_HOST: ...
#
# The chart's shipped DATABASE_HOST default is the hardcoded FQDN
# "plugin-br-pix-direct-jd-postgresql.midaz-plugins.svc.cluster.local", which
# only resolves for one release name in one namespace. Overriding it with the
# value below is not optional in any real deployment.
#
# THERE IS NO POSTGRES_HOST KEY in this chart — DATABASE_HOST is the only host
# variable. Emitting POSTGRES_HOST would land in the ConfigMap as an unread key.
#
# NOT emitted here, on purpose:
#   DATABASE_PASSWORD / POSTGRES_PASSWORD — read from secret_name by External
#     Secrets, never an output. Both names carry the same value; the deployment
#     wires them from the same source.
#   DATABASE_ACQUIRE / _IDLE / _POOL_MAX / _POOL_MIN — client pool tuning, a
#     workload decision with no honest infrastructure value.
#   any SSL/TLS mode — the chart has NO sslmode variable of any kind (verified:
#     grep for "sslmode" returns nothing). Whether the driver negotiates TLS
#     against RDS is decided in the application, not through this chart. That is
#     a gap worth raising with the service owner, not something Terraform can
#     paper over.
################################################################################

output "helm_values" {
  description = "plugin-br-pix-direct-jd chart env vars this datastore fills in, ready to merge into .Values.pix.configmap — which also drives the CronJob, because the job ConfigMap reads pix.configmap. Pair it with postgresql.enabled = false and postgresql.external = true so the bundled Bitnami subchart is not deployed alongside RDS."
  value = {
    DATABASE_HOST = module.postgres.endpoint
    DATABASE_PORT = tostring(module.postgres.port)
    DATABASE_USER = module.postgres.username
    DATABASE_NAME = module.postgres.database_name

    # The "docker-compose compatibility" trio the chart also renders
    # (configmap.yaml:91-93). Kept consistent with the DATABASE_* values above
    # so the two families can never disagree; there is no POSTGRES_HOST.
    POSTGRES_USER = module.postgres.username
    POSTGRES_DB   = module.postgres.database_name
    POSTGRES_PORT = tostring(module.postgres.port)
  }
}
