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
  description = "EKS cluster whose node security group was looked up. Should equal the cluster_name output of infra-base/eks. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to tracer."
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
  description = "ARN of the Secrets Manager secret holding the master credentials: tracer-{env}-postgres/password in dedicated mode, shared-{env}-postgres/password in shared mode."
  value       = module.postgres.secret_arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret holding the master credentials. This is the value an External Secrets Operator ExternalSecret references to populate the chart's DB_PASSWORD (tracer.secrets.DB_PASSWORD, values.yaml:275)."
  value       = module.postgres.secret_name
}

output "identifier" {
  description = "RDS DB instance identifier: tracer-{environment}-postgres in dedicated mode, the resolved shared-{env}-postgres in shared mode."
  value       = module.postgres.identifier
}

################################################################################
# PostgreSQL specifics
################################################################################

output "database_name" {
  description = "Name of the initial database RDS created. tracer runs a SINGLE logical database, so unlike the midaz root this value is complete and is emitted to the chart as DB_NAME."
  value       = module.postgres.database_name
}

output "username" {
  description = "Master username of the instance. Feeds DB_USER. The chart's own default is \"tracer\", a least-privilege role that does not exist on a fresh RDS instance until someone creates it."
  value       = module.postgres.username
}

output "replica_endpoint" {
  description = "Raw AWS hostname of the read replica. Null when no replica was created, and null in shared mode. The tracer chart has no reader variable, so nothing consumes this today."
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
# The exact env var names the TRACER chart reads. Verified against chart
# tracer-helm 2.1.0 (appVersion 1.0.0), templates/configmap.yaml lines 30-33 and
# values.yaml lines 202-206.
#
# These are NOT the midaz names. tracer uses the short, unsuffixed DB_* family
# (DB_HOST / DB_PORT / DB_NAME / DB_USER); midaz uses DB_ONBOARDING_* and
# DB_TRANSACTION_* and has no plain DB_HOST on its application containers at
# all. Copying either chart's block into the other produces a release that
# silently keeps the chart defaults.
#
# Everything below lands on `tracer.configmap`, which templates/configmap.yaml
# renders into the ConfigMap the tracer Deployment consumes with envFrom.
#
# Values are strings because they end up in a ConfigMap, which has no other
# type.
#
# NOT emitted here, on purpose:
#   DB_PASSWORD  — read from secret_name by External Secrets, never an output.
#                  It is tracer.secrets.DB_PASSWORD (values.yaml:275), rendered
#                  by templates/secrets.yaml.
#   DB_SSL_MODE  — a client policy decision, not an infrastructure fact, and the
#                  same call the midaz root makes about its DB_*_SSLMODE. RDS
#                  accepts TLS on every instance whatever the client asks for;
#                  the chart default is "disable" (values.yaml:206). Set it
#                  deliberately in values, not from here.
#   MIGRATIONS_PATH — an application path (values default "./migrations"), no
#                  relationship to the instance.
#   The global.externalPostgresDefinitions.* block — the chart ships an OPTIONAL
#                  bootstrap Job (templates/bootstrap-postgres.yaml, default off
#                  at values.yaml:12) that creates the tracer database and role
#                  on an external instance using an ADMIN login. If that Job is
#                  used, its connection.host / connection.port take the same
#                  endpoint and port as below, and its postgresAdminLogin needs
#                  the master credentials from secret_name. It is deliberately
#                  not wired here: handing a Job the RDS master password is a
#                  decision for whoever operates the cluster, not a Terraform
#                  default.
################################################################################

output "helm_values" {
  description = "tracer chart env vars this datastore fills in, ready to merge into tracer.configmap. The tracer chart declares no PostgreSQL subchart at all (Chart.yaml has no dependencies block), so there is no postgresql.enabled to turn off — but the chart's default DB_HOST points at an in-cluster service named tracer-postgresql (values.yaml:202), so leaving these unset silently aims the release at a Postgres that this Terraform did not create."
  value = {
    DB_HOST = module.postgres.endpoint
    DB_PORT = tostring(module.postgres.port)
    DB_NAME = module.postgres.database_name
    DB_USER = module.postgres.username
  }
}
