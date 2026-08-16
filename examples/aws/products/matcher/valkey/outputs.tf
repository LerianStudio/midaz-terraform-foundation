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
# datastore — so a plain module.valkey.x reference is safe. The one(...)
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
  description = "tag:Name of the VPC the replication group was placed in, as derived or overridden. Should equal the vpc_name output of infra-base/vpc."
  value       = module.network.vpc_name
}

output "eks_cluster_name" {
  description = "EKS cluster whose node security group was looked up. Should equal the cluster_name output of infra-base/eks. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to matcher."
  value       = module.network.eks_cluster_name
}

output "ingress_security_group_ids" {
  description = "Security groups authorised on the replication group. Empty before infra-base/eks exists unless allowed_security_group_ids was passed explicitly."
  value       = module.network.ingress_security_group_ids
}

output "ingress_cidr_blocks" {
  description = "CIDR blocks authorised on the replication group. Holds the Type=private subnet CIDRs while allow_private_subnet_cidr_ingress is true."
  value       = module.network.ingress_cidr_blocks
}

################################################################################
# Uniform datastore contract
################################################################################

output "mode" {
  description = "Provisioning mode this stack ran in: dedicated or shared."
  value       = module.valkey.mode
}

output "endpoint" {
  description = "Raw AWS primary endpoint of the replication group. In shared mode this is the primary endpoint of shared-{env}-valkey, resolved by name. It is the raw endpoint on purpose: with transit encryption on, the ElastiCache certificate only covers *.{cluster}.{region}.cache.amazonaws.com. Whether the release wants this bare or concatenated with the port is a chart question this repository cannot answer for Matcher."
  value       = module.valkey.endpoint
}

output "port" {
  description = "Valkey port, published separately. Fold it into the host string only if the chart turns out to want that."
  value       = module.valkey.port
}

output "security_group_id" {
  description = "Security group protecting the replication group. Null in shared mode — ingress on the shared replication group is owned by products/shared-resources/valkey."
  value       = module.valkey.security_group_id
}

output "secret_arn" {
  description = "ARN of the Secrets Manager secret holding the auth token: matcher-{env}-valkey/auth-token in dedicated mode, shared-{env}-valkey/auth-token in shared mode."
  value       = module.valkey.secret_arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret holding the auth token. This is the value an External Secrets Operator ExternalSecret references."
  value       = module.valkey.secret_name
}

output "identifier" {
  description = "ElastiCache replication group id: matcher-{environment}-valkey in dedicated mode, the resolved shared-{env}-valkey in shared mode."
  value       = module.valkey.identifier
}

################################################################################
# Valkey specifics
################################################################################

output "reader_endpoint" {
  description = "Reader endpoint of the replication group. Resolved from the shared group in shared mode; empty when the group has a single cache cluster."
  value       = module.valkey.reader_endpoint
}

output "engine_version_actual" {
  description = "Running version of the cache engine. Null in shared mode."
  value       = module.valkey.engine_version_actual
}

output "auth_token_enabled" {
  description = "Whether ElastiCache is ENFORCING the auth token stored in secret_name. False means the token exists but is not required."
  value       = module.valkey.auth_token_enabled
}

output "transit_encryption_enabled" {
  description = "Whether in-transit encryption is enabled on the replication group. Available is not the same as required — see transit_encryption_mode."
  value       = module.valkey.transit_encryption_enabled
}

output "subnet_group_name" {
  description = "Name of the cache subnet group. Null in shared mode."
  value       = module.valkey.subnet_group_name
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
# valkey-2.4.7.tgz is the Bitnami Valkey chart — the same version midaz and
# plugin-br-bank-transfer vendor. Solid evidence of a `valkey` dependency, and
# nothing more.
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
# For orientation only, NOT a recommendation to hardcode: midaz and
# plugin-br-bank-transfer want REDIS_HOST as "host:port" with no REDIS_PORT key,
# notifications wants a bare REDIS_HOST plus a separate REDIS_PORT, and
# plugin-br-pix-indirect-btg does BOTH depending on the component. There is no
# Lerian convention to fall back on.
################################################################################

output "helm_values" {
  description = "EMPTY ON PURPOSE. The Matcher chart is not in this repository (only its vendored dependency tarballs are), so the env var names it reads cannot be verified. Inventing them would produce a map that looks authoritative and fails at runtime. Use the endpoint, port, username, secret_name and identifier outputs above to wire the release by hand, and fill this in once the chart is available. See the header of this file and the 'Inferred composition' section of ../README.md."
  value       = {}
}
