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
# cluster — so a plain module.documentdb.x reference is safe. The
# one(...) gymnastics live inside the module, where the count actually is.
################################################################################

locals {
  ##############################################################################
  # Connection-string parameters that are properties of DocumentDB itself, not
  # client preferences:
  #
  #   retryWrites=false  DocumentDB does not implement retryable writes. Drivers
  #                      default them ON, so omitting this makes every write fail.
  #   tls=true           mirrors the cluster `tls` parameter. Pair it with
  #                      MONGO_TLS_CA_CERT in the chart (the global RDS CA
  #                      bundle), which Terraform does not distribute.
  #
  # CONFIRMAR no chart: whether the application joins MONGO_PARAMETERS onto the
  # connection string with a leading "?" or expects one already present. The
  # chart default is the empty string, so there is no worked example to copy.
  # The value below carries no separator.
  ##############################################################################
  mongo_parameters = join("&", compact([
    "retryWrites=false",
    var.documentdb_tls == "enabled" ? "tls=true" : "",
  ]))
}

################################################################################
# Cross-stack context (assert the derived strings without opening the tfvars)
#
# Re-exported from module.network, which owns the derivation. Note the "lerian"
# prefix on the VPC and the cluster: those are FOUNDATION names and keep it,
# while the shared datastore tier carries "shared".
################################################################################

output "vpc_name" {
  description = "tag:Name of the VPC the cluster was placed in, as derived or overridden. Should equal the vpc_name output of infra-base/vpc."
  value       = module.network.vpc_name
}

output "eks_cluster_name" {
  description = "EKS cluster whose node security group was looked up. Should equal the cluster_name output of infra-base/eks. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to fetcher."
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
  description = "Security group protecting the cluster. Null in shared mode — ingress on the shared one is owned by products/shared-resources/documentdb."
  value       = module.documentdb.security_group_id
}

output "secret_arn" {
  description = "ARN of the Secrets Manager secret holding the master password: fetcher-{env}-docdb/password in dedicated mode, shared-{env}-docdb/password in shared mode."
  value       = module.documentdb.secret_arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret holding the master password. This is the value an External Secrets Operator ExternalSecret references to populate MONGO_PASSWORD."
  value       = module.documentdb.secret_name
}

output "identifier" {
  description = "DocumentDB cluster identifier: fetcher-{environment}-docdb in dedicated mode, the resolved shared-{env}-docdb in shared mode."
  value       = module.documentdb.identifier
}

################################################################################
# DocumentDB specifics
################################################################################

output "reader_endpoint" {
  description = "Raw AWS reader endpoint of the cluster, for read-only consumers. Resolved from the shared cluster in shared mode. The fetcher-helm chart has no read-only Mongo variable today, so this is published for operators rather than consumed by the release."
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
# Verified against fetcher-helm 3.1.0 (appVersion 3.0.2): values.yaml
# `common.configmap` (the MongoDB block) and `secrets:`, rendered by
# templates/common/configmap.yaml into a single "-common" ConfigMap that both
# templates/manager/deployment.yaml and templates/worker/deployment.yaml mount
# with envFrom.
#
# ONE UNSUFFIXED SET, like reporter and unlike midaz — the manager and the worker
# are the same application against the same database.
#
# MONGO_URI is a SCHEME, not a connection string. "mongodb" is the only correct
# value for DocumentDB: it publishes no SRV records, so "mongodb+srv" cannot
# resolve.
#
# DESTINATION NOTE, and it differs from reporter: this chart keeps MONGO_USER
# under the top-level `secrets:` map, NOT in common.configmap. Every other key
# below goes to common.configmap. Merging MONGO_USER into the ConfigMap leaves
# the Secret key at its "fetcher" default and the application authenticates as
# the wrong role.
#
# NOT emitted here, on purpose:
#   MONGO_NAME          — the chart default is "fetcher-db". DocumentDB creates a
#     database lazily on first write, so Terraform never creates it.
#   MONGO_PASSWORD      — read from secret_name by External Secrets.
#   MONGO_TLS_CA_CERT   — the global RDS CA bundle, not produced by Terraform.
#   MONGO_MAX_POOL_SIZE — application tuning (chart default 1000).
################################################################################

output "helm_values" {
  description = "fetcher chart env vars this datastore fills in. All keys merge into common.configmap EXCEPT MONGO_USER, which this chart keeps under the top-level secrets map. The fetcher chart already ships mongodb.enabled = false, so nothing has to be turned off — it expects an external cluster by default, unlike reporter."
  value = {
    MONGO_URI        = "mongodb"
    MONGO_HOST       = module.documentdb.endpoint
    MONGO_PORT       = tostring(module.documentdb.port)
    MONGO_PARAMETERS = local.mongo_parameters

    # Belongs under the top-level `secrets:` map, not `common.configmap`.
    MONGO_USER = var.master_username
  }
}
