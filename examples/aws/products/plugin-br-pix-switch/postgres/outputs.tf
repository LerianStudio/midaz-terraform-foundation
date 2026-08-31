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
  ################################################################################
  # The three application databases the chart creates on this instance.
  #
  # Mirrors global.externalPostgresDefinitions.databases (values.yaml:68-71). It
  # is a LOCAL rather than a variable on purpose: Terraform does not create these
  # and changing the list here would not change what the chart does. It exists so
  # database_url_templates below can be generated instead of hand-written.
  ################################################################################
  chart_databases = ["pix-spi", "pix-dict", "pix-cob"]

  ################################################################################
  # DSN templates, with the password left as a literal placeholder.
  #
  # sslmode=require matches the chart's own examples (values-template.yaml:42,58,
  # 85 and every other DATABASE_URL line). RDS accepts TLS on every instance, and
  # "require" encrypts without verifying the CA — which is what the chart asks
  # for; "verify-full" would additionally need the RDS CA bundle mounted, which
  # Terraform does not distribute.
  ################################################################################
  database_url_templates = {
    for db in local.chart_databases :
    db => "postgres://pixswitch:<password>@${module.postgres.endpoint}:${module.postgres.port}/${db}?sslmode=require"
  }
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
  description = "EKS cluster whose node security group was looked up. Should equal the cluster_name output of infra-base/eks. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to plugin-br-pix-switch."
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
  description = "ARN of the Secrets Manager secret holding the master credentials: plugin-br-pix-switch-{env}-postgres/password in dedicated mode, shared-{env}-postgres/password in shared mode."
  value       = module.postgres.secret_arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret holding the master credentials. This is the value an External Secrets Operator ExternalSecret references to populate the ADMIN password the chart's bootstrap Job authenticates with. It is NOT the application role's password — that one is created by the Job from a value the operator supplies, and it is the one that belongs in the DATABASE_URL / SYSTEMPLANE_POSTGRES_DSN secrets."
  value       = module.postgres.secret_name
}

output "identifier" {
  description = "RDS DB instance identifier: plugin-br-pix-switch-{environment}-postgres in dedicated mode, the resolved shared-{env}-postgres in shared mode."
  value       = module.postgres.identifier
}

################################################################################
# PostgreSQL specifics
################################################################################

output "database_name" {
  description = "Name of the INITIAL database RDS created. Nothing in the release reads it: the three application databases (pix-spi, pix-dict, pix-cob) are created by the chart's own bootstrap Job, which connects to the hardcoded \"postgres\" maintenance database."
  value       = module.postgres.database_name
}

output "username" {
  description = "Master username — the ADMIN account, which is what the chart's bootstrap Job authenticates with. The APPLICATION role (default \"pixswitch\") is created by that Job and is a different credential."
  value       = module.postgres.username
}

output "chart_databases" {
  description = "The three databases the chart's bootstrap Job creates on this instance, mirroring global.externalPostgresDefinitions.databases. Terraform creates none of them; this is published so an operator can assert the list matches the release values."
  value       = local.chart_databases
}

output "database_url_templates" {
  description = "One DATABASE_URL / SYSTEMPLANE_POSTGRES_DSN template per application database, with the password left as the literal placeholder <password>. Substitute the APPLICATION role's password (the one given to global.externalPostgresDefinitions.pixswitchCredentials), NOT the admin password behind secret_name. Percent-encode it if it is not URL-safe."
  value       = local.database_url_templates
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
# READ THIS FIRST: THIS MAP IS HELM VALUE PATHS, NOT ENV VARS.
#
# Every other product in this repository emits a map of environment variable
# names, because every other chart reads host/port/user as separate ConfigMap
# keys. plugin-br-pix-switch does not. Verified against chart 2.0.0-beta.1+:
#
#   values-template.yaml:42-43,58-59,85-86,100,124-125,141-142,162-163
#       every component reads Postgres through DATABASE_URL and
#       SYSTEMPLANE_POSTGRES_DSN — FULL postgres:// URLs, and both live under
#       <component>.secrets, not .configmap
#   templates/spi/secrets.yaml:13-15
#       the secrets map is emitted verbatim into a Secret; there is no host key,
#       no port key and no user key anywhere in the component surface
#
# TERRAFORM CANNOT FILL A SECRET. A DSN carries the password, and this repository
# never emits a password. So the DSNs are published as TEMPLATES instead — see
# the database_url_templates output above — and the operator substitutes the
# application role's password from Secrets Manager.
#
# WHAT *IS* NON-SECRET, AND IS EMITTED BELOW: the chart's bootstrap Job reads
# host and port as plain values under global.externalPostgresDefinitions
# (values.yaml:72-74), and the admin username under postgresAdminLogin
# (values.yaml:79). Those three are exactly what this stack knows and the chart
# consumes without a secret, so they are the whole map — keyed by their Helm
# value PATH, because that is what they are.
#
# THE ADMIN USERNAME MATTERS. The bootstrap Job runs CREATE ROLE and CREATE
# DATABASE as that account. It defaults to "postgres" in the chart and this stack
# defaults the RDS master username to "postgres" for exactly that reason, but the
# key is emitted so an override on either side cannot drift silently.
#
# NOT emitted here, on purpose:
#   global.externalPostgresDefinitions.postgresAdminLogin.password — the master
#     password, read from secret_name by External Secrets. Prefer
#     postgresAdminLogin.useExistingSecret.name over an inline value; the chart
#     itself says "Never put real admin passwords in values.yaml"
#     (values.yaml:61).
#   global.externalPostgresDefinitions.pixswitchCredentials.* — the APPLICATION
#     role. Terraform does not create it; the bootstrap Job does, from a password
#     the operator supplies. It is NOT the master password.
#   global.externalPostgresDefinitions.enabled — a deployment decision. Set it
#     true to have the chart provision the three databases on this instance.
#   global.externalPostgresDefinitions.databases — published separately as the
#     chart_databases output rather than as a value to copy, because Terraform
#     does not decide it.
################################################################################

output "helm_values" {
  description = "plugin-br-pix-switch HELM VALUE PATHS (not env vars — see the header) that this datastore fills in: the bootstrap Job's connection host and port, and the admin username it authenticates with. The per-component DATABASE_URL / SYSTEMPLANE_POSTGRES_DSN values are SECRETS and are published as database_url_templates instead. Pair with postgresql.enabled = false; the chart ships that default already."
  value = {
    "global.externalPostgresDefinitions.connection.host"             = module.postgres.endpoint
    "global.externalPostgresDefinitions.connection.port"             = tostring(module.postgres.port)
    "global.externalPostgresDefinitions.postgresAdminLogin.username" = module.postgres.username
  }
}
