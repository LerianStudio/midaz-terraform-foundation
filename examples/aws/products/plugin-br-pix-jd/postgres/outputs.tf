################################################################################
# ⚠ THE PLUGIN-BR-PIX-JD CHART IS NOT IN THIS REPOSITORY.
#
# infrastructure/K8S/helm/charts/plugin-br-pix-jd/ contains no Chart.yaml, no
# values.yaml and no templates/ — only a charts/ directory holding two vendored
# tarballs:
#
#   charts/postgresql-16.3.5.tgz        Bitnami postgresql (appVersion 17.2.0)
#   charts/lerian-common-helm-1.3.4.tgz Lerian's own LIBRARY chart
#
# Neither is the product's chart. The second one is Lerian-authored but is
# `type: library` — it renders nothing on its own and only ships helper
# templates. Its _datastore.tpl helper takes the real env var name as a
# CALLER-SUPPLIED argument (its own doc comment: "nativeKey (req) the product's
# real env key"), which means even the Lerian library deliberately refuses to
# know what plugin-br-pix-jd calls its variables. The DB_ONBOARDING_HOST /
# DB_LEDGER_HOST / DB_FEES_HOST examples in that library's docs belong to OTHER
# products and must not be copied here.
#
# CONSEQUENCE: helm_values below is DELIBERATELY EMPTY.
#
# The infrastructure is real and correct. Only the chart translation is missing,
# and a wrong env var name fails silently — not at plan time, not at Helm render
# time, not at pod start, but in production, as a service quietly talking to the
# chart's in-cluster default while this RDS instance sits idle.
#
# ALSO INFERRED, and worth confirming: that this product needs PostgreSQL and
# NOTHING ELSE. The evidence is the shape of the vendored set — a postgresql
# tarball is present and no valkey, mongodb or rabbitmq tarball is. That is why
# this product has a single service directory. It is a reasonable reading of
# what someone vendored, not a statement from the chart.
#
# TO CLOSE THIS: read the plugin-br-pix-jd chart's values.yaml and the template
# that renders its ConfigMap. Three distinct shapes already exist across the
# readable Lerian charts, so do not copy another product's block:
#
#   midaz                  DB_ONBOARDING_* / DB_TRANSACTION_*, no plain DB_HOST
#   tracer                 DB_HOST / DB_PORT / DB_NAME / DB_USER
#   br-consignado-gw       POSTGRES_HOST / POSTGRES_PORT / POSTGRES_USER / POSTGRES_NAME
#   plugin-access-manager  DB_* on the auth component only, aliased subchart
################################################################################

################################################################################
# Cross-stack context (assert the derived strings without opening the tfvars)
################################################################################

output "vpc_name" {
  description = "tag:Name of the VPC the instance was placed in, as derived or overridden. Should equal the vpc_name output of infra-base/vpc."
  value       = module.network.vpc_name
}

output "eks_cluster_name" {
  description = "EKS cluster whose node security group was looked up. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to plugin-br-pix-jd."
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
  description = "Raw AWS hostname of the instance. In shared mode this is the hostname of shared-{env}-postgres, resolved by name."
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
  description = "ARN of the Secrets Manager secret holding the master credentials: plugin-br-pix-jd-{env}-postgres/password in dedicated mode, shared-{env}-postgres/password in shared mode."
  value       = module.postgres.secret_arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret holding the master credentials. The chart key an External Secrets Operator ExternalSecret should target is unknown — the chart is not in this repository."
  value       = module.postgres.secret_name
}

output "identifier" {
  description = "RDS DB instance identifier: plugin-br-pix-jd-{environment}-postgres in dedicated mode, the resolved shared-{env}-postgres in shared mode."
  value       = module.postgres.identifier
}

################################################################################
# PostgreSQL specifics
################################################################################

output "database_name" {
  description = "Name of the initial database RDS created. INFERRED — no chart states the name the application expects; confirm with the owning team before the first release."
  value       = module.postgres.database_name
}

output "username" {
  description = "Master username of the instance."
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
# Helm handoff — EMPTY ON PURPOSE
#
# See the block at the top of this file. The values a consumer needs are all
# published above as first-class outputs (endpoint, port, database_name,
# username, secret_name), so wiring the release by hand once the chart is known
# is a five-minute job:
#
#   terraform output -raw endpoint
#   terraform output -raw port
#   terraform output -raw database_name
#   terraform output -raw username
#   terraform output -raw secret_name
################################################################################

output "helm_values" {
  description = "EMPTY BY DESIGN. The plugin-br-pix-jd chart is not in this repository (only a Bitnami postgresql tarball and the lerian-common-helm library chart), so the env var names it reads are unknown and are not guessed here. Read endpoint / port / database_name / username / secret_name individually and map them by hand once the chart is available. See the comment block at the top of outputs.tf."
  value       = {}
}
