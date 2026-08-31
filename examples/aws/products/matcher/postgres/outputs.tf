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
  description = "EKS cluster whose node security group was looked up. Should equal the cluster_name output of infra-base/eks. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to matcher."
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
  description = "ARN of the Secrets Manager secret holding the master credentials: matcher-{env}-postgres/password in dedicated mode, shared-{env}-postgres/password in shared mode."
  value       = module.postgres.secret_arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret holding the master credentials. This is the value an External Secrets Operator ExternalSecret references."
  value       = module.postgres.secret_name
}

output "identifier" {
  description = "RDS DB instance identifier: matcher-{environment}-postgres in dedicated mode, the resolved shared-{env}-postgres in shared mode."
  value       = module.postgres.identifier
}

################################################################################
# PostgreSQL specifics
################################################################################

output "database_name" {
  description = "Name of the initial database RDS created. An infrastructure choice, not a chart default — see the database_name variable. Point the release at this value rather than assuming it."
  value       = module.postgres.database_name
}

output "username" {
  description = "Master username of the instance. An infrastructure choice, not a chart default."
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
# Helm handoff — DELIBERATELY EMPTY
#
# THERE IS NO CHART TO MAP TO. infrastructure/K8S/helm/charts/matcher/ contains
# exactly one thing:
#
#     matcher/
#     └── charts/
#         ├── postgresql-16.3.5.tgz
#         ├── valkey-2.4.7.tgz
#         └── rabbitmq-2.1.11.tgz
#
# No Chart.yaml. No values.yaml. No values-template.yaml. No templates/. No
# Chart.lock. Only the vendored dependency tarballs a `helm dependency update`
# left behind, from a chart whose own source is not in this repository.
#
# postgresql-16.3.5.tgz is Bitnami's PostgreSQL chart — the SAME version midaz,
# plugin-br-bank-transfer and plugin-br-pix-indirect-btg vendor. Its presence is
# solid evidence that the Matcher chart declares a `postgresql` dependency; it says
# nothing whatsoever about which env vars the application reads.
#
# What that means for this output: the resource names, the endpoints, the ports
# and the secret paths below are all real and verifiable — they come from AWS,
# not from a chart. The ENV VAR NAMES the Matcher application reads are not
# knowable from here, and this repository has already been bitten three times by
# assuming one chart's names apply to another:
#
#   - midaz removed REDIS_PORT in chart 3.0 and folds the port into REDIS_HOST;
#     notifications keeps them split. Same company, opposite shapes.
#   - RABBITMQ_PORT_HOST means the AMQP port in the midaz chart and the
#     MANAGEMENT port in the notifications chart. Same two names, swapped.
#   - The PostgreSQL host key is POSTGRES_HOST in two charts, DB_HOST in a third
#     and DB_ONBOARDING_HOST / DB_TRANSACTION_HOST in a fourth.
#
# An invented map would look authoritative and break in production. An empty one
# is honest and costs a five-minute conversation with the Matcher team.
#
# WHAT TO DO WHEN THE CHART LANDS:
#   1. Read its values.yaml and its configmap templates — not another product's.
#   2. Fill this output with the names that are actually there.
#   3. Delete this comment block and the "inferred composition" section of
#      ../README.md.
#
# For orientation only, NOT a recommendation to hardcode: the three readable
# Lerian charts spell this datastore POSTGRES_HOST/PORT/USER plus one of
# POSTGRES_DB or POSTGRES_NAME, or DB_HOST/PORT/USER/NAME. Matcher uses one of
# those, or something else. Confirm, do not assume.
################################################################################

output "helm_values" {
  description = "EMPTY ON PURPOSE. The Matcher chart is not in this repository (only its vendored dependency tarballs are), so the env var names it reads cannot be verified. Inventing them would produce a map that looks authoritative and fails at runtime. Use the endpoint, port, username, secret_name and identifier outputs above to wire the release by hand, and fill this in once the chart is available. See the header of this file and the 'Inferred composition' section of ../README.md."
  value       = {}
}
