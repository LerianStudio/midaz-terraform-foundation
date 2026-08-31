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
# datastore — so a plain module.documentdb.x reference is safe.
################################################################################

locals {
  ################################################################################
  # MONGO_PARAMETERS — connection-string options that are properties of
  # DocumentDB itself, not client preferences. Emitted with NO leading "?".
  #
  #   retryWrites=false  DocumentDB does not implement retryable writes. Drivers
  #                      default them ON, so omitting this makes every write fail.
  #   tls=true           mirrors the cluster `tls` parameter. Pair it with
  #                      MONGO_TLS_CA_CERT in the chart (the global RDS CA
  #                      bundle), which Terraform does not distribute.
  #
  # CONFIRMAR no chart: whether the fee engine joins MONGO_PARAMETERS onto the
  # connection string with a leading "?" or expects one already present. The
  # chart default is the empty string, which tells us nothing either way, and no
  # template concatenates it. The value below carries no separator, matching the
  # convention every other Lerian root in this repository uses.
  ################################################################################
  mongo_parameters = join("&", compact([
    "retryWrites=false",
    var.documentdb_tls == "enabled" ? "tls=true" : "",
  ]))
}

################################################################################
# Cross-stack context (assert the derived strings without opening the tfvars)
################################################################################

output "vpc_name" {
  description = "tag:Name of the VPC the cluster was placed in, as derived or overridden. Should equal the vpc_name output of infra-base/vpc."
  value       = module.network.vpc_name
}

output "eks_cluster_name" {
  description = "EKS cluster whose node security group was looked up. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to plugin-fees."
  value       = module.network.eks_cluster_name
}

output "ingress_security_group_ids" {
  description = "Security groups authorised on the cluster. Empty before infra-base/eks exists unless allowed_security_group_ids was passed explicitly."
  value       = module.network.ingress_security_group_ids
}

output "ingress_cidr_blocks" {
  description = "CIDR blocks authorised on the cluster. Holds the Type=private subnet CIDRs while allow_private_subnet_cidr_ingress is true."
  value       = module.network.ingress_cidr_blocks
}

################################################################################
# Uniform datastore contract
################################################################################

output "mode" {
  description = "Provisioning mode this stack ran in: dedicated or shared."
  value       = module.documentdb.mode
}

output "endpoint" {
  description = "Raw AWS writer endpoint of the cluster — the MONGO_HOST the Helm release connects to. In shared mode this is the writer endpoint of shared-{env}-docdb, resolved by identifier."
  value       = module.documentdb.endpoint
}

output "port" {
  description = "Port the cluster listens on."
  value       = module.documentdb.port
}

output "security_group_id" {
  description = "Security group protecting the cluster. Null in shared mode — ingress on the shared cluster is owned by products/shared-resources/documentdb."
  value       = module.documentdb.security_group_id
}

output "secret_arn" {
  description = "ARN of the Secrets Manager secret holding the master password: plugin-fees-{env}-docdb/password in dedicated mode, shared-{env}-docdb/password in shared mode."
  value       = module.documentdb.secret_arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret holding the master password. This is the value an External Secrets Operator ExternalSecret references to populate the chart's MONGO_PASSWORD key. Note the chart prefers the Bitnami mongodb subchart Secret whenever that subchart is enabled and not external, so mongodb.enabled = false is what makes this secret take effect."
  value       = module.documentdb.secret_name
}

output "identifier" {
  description = "DocumentDB cluster identifier: plugin-fees-{environment}-docdb in dedicated mode, the resolved shared-{env}-docdb in shared mode."
  value       = module.documentdb.identifier
}

################################################################################
# DocumentDB specifics
################################################################################

output "reader_endpoint" {
  description = "Raw AWS reader endpoint of the cluster, for read-only consumers. Resolved from the shared cluster in shared mode. The plugin-fees chart has no read-only Mongo variable today, so this is published for operators rather than consumed by the release."
  value       = module.documentdb.reader_endpoint
}

output "arn" {
  description = "ARN of the DocumentDB cluster. Resolved from the shared cluster in shared mode."
  value       = module.documentdb.arn
}

output "kms_key_arn" {
  description = "ARN of the CMK encrypting the cluster storage. Null in shared mode."
  value       = module.documentdb.kms_key_arn
}

output "master_username" {
  description = "Master username configured on the cluster. Read from the stack variable rather than from the module output, which is marked sensitive and would redact anything it is merged into."
  value       = var.master_username
}

output "tls_enabled" {
  description = "Whether the cluster `tls` parameter is enabled. It does not change which host helm_values emits — that is always the raw endpoint — only whether MONGO_PARAMETERS carries tls=true."
  value       = var.documentdb_tls == "enabled"
}

################################################################################
# Helm handoff
#
# The exact env var names the plugin-fees chart reads, so wiring the release is
# a copy, not a translation. Verified against chart plugin-fees-helm 7.3.0
# (appVersion 3.4.0), templates/fees/configmap.yaml lines 25-34.
#
# THE UNSUFFIXED FAMILY. plugin-fees reads MONGO_HOST / MONGO_PORT / MONGO_USER,
# not midaz's MONGO_ONBOARDING_* / MONGO_TRANSACTION_* pair, and not
# product-console's MONGODB_USER / MONGODB_DB_NAME hybrid. Three Lerian charts,
# three spellings; each was read separately.
#
# MONGO_URI is NOT a connection string — the chart ships the bare word "mongodb"
# and the application assembles the URI from the surrounding variables.
# "mongodb" is the only correct value for DocumentDB: it publishes no SRV
# records, so "mongodb+srv" cannot resolve.
#
# These keys land in .Values.fees.configmap.
#
# NOT emitted here, on purpose:
#   MONGO_NAME  — the chart default is "plugin-fees-db"; DocumentDB creates a
#     database lazily on first write, so Terraform never creates it and must not
#     claim to know it. Leave the chart default alone.
#   MONGO_PASSWORD — read from secret_name by External Secrets, never an output.
#   MONGO_TLS_CA_CERT — the global RDS CA bundle, distributed with the chart or
#     mounted from a ConfigMap, not produced by Terraform. The variable DOES
#     exist here (unlike in product-console), which is what makes
#     documentdb_tls = "enabled" reachable for this product.
#   MONGO_MAX_POOL_SIZE / MONGO_MIN_POOL_SIZE / MONGO_MAX_CONN_IDLE_TIME_SECONDS
#     — client pool tuning. They should track instance_class, but the mapping is
#     a workload decision and Terraform has no honest value for it.
################################################################################

output "helm_values" {
  description = "plugin-fees chart env vars this datastore fills in, ready to merge into .Values.fees.configmap. Pair it with mongodb.enabled = false and mongodb.external = true (values.yaml defaults are true/false) so the bundled Bitnami subchart is not deployed alongside DocumentDB and MONGO_PASSWORD is read from the chart's own Secret."
  value = {
    MONGO_URI        = "mongodb"
    MONGO_HOST       = module.documentdb.endpoint
    MONGO_PORT       = tostring(module.documentdb.port)
    MONGO_USER       = var.master_username
    MONGO_PARAMETERS = local.mongo_parameters
  }
}
