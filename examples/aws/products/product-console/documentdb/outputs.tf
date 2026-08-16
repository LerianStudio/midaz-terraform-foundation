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
  # DocumentDB itself, not client preferences. Emitted with NO leading "?": the
  # application appends the separator.
  #
  #   retryWrites=false  DocumentDB does not implement retryable writes. Drivers
  #                      default them ON, so omitting this makes every write fail.
  #   tls=true           mirrors the cluster `tls` parameter.
  #
  # The chart's own DocumentDB recipe (docs/UPGRADE-2.0.md:93) is longer:
  #   "tls=true&tlsInsecure=true&directConnection=true&retryWrites=false"
  #
  # Two of those four are deliberately NOT emitted here:
  #
  #   tlsInsecure=true       disables certificate validation outright. It is in
  #                          the chart docs because the older wiring put a
  #                          private CNAME in front of the cluster, and no
  #                          validating driver could accept that name. This repo
  #                          has no private zone: MONGO_HOST is the raw
  #                          *.docdb.amazonaws.com endpoint, which the DocumentDB
  #                          certificate covers, so validation passes on its own
  #                          merits. Emitting tlsInsecure would silently throw
  #                          that away.
  #   directConnection=true  a topology decision (bypass replica-set discovery
  #                          and pin the driver to the writer). Correct for a
  #                          single-instance cluster, wrong the moment
  #                          instances_count > 1, and Terraform must not choose
  #                          it on the operator's behalf. Append it through the
  #                          chart's configmap.MONGO_PARAMETERS if you want it.
  ################################################################################
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
  description = "EKS cluster whose node security group was looked up. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to product-console."
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
  description = "ARN of the Secrets Manager secret holding the master password: product-console-{env}-docdb/password in dedicated mode, shared-{env}-docdb/password in shared mode."
  value       = module.documentdb.secret_arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret holding the master password. This is the value an External Secrets Operator ExternalSecret references to populate the chart's secrets.MONGODB_PASS key."
  value       = module.documentdb.secret_name
}

output "identifier" {
  description = "DocumentDB cluster identifier: product-console-{environment}-docdb in dedicated mode, the resolved shared-{env}-docdb in shared mode."
  value       = module.documentdb.identifier
}

################################################################################
# DocumentDB specifics
################################################################################

output "reader_endpoint" {
  description = "Raw AWS reader endpoint of the cluster, for read-only consumers. Resolved from the shared cluster in shared mode. The product-console chart has no read-only Mongo variable, so this is published for operators rather than consumed by the release."
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
# The exact env var names the product-console chart reads, so wiring the release
# is a copy, not a translation. Verified against chart product-console-helm
# 3.3.0 (appVersion 1.10.0): values.yaml:226-233 (the `configmap:` map, rendered
# by templates/configmap.yaml:9-11) and values.yaml:259 (the `secrets:` map,
# rendered by templates/secrets.yaml:11-13).
#
# THIS CHART DOES NOT USE THE SIBLING NAMING. Every other Lerian chart spells
# these MONGO_NAME / MONGO_USER / MONGO_PASSWORD; product-console spells three of
# them MONGODB_DB_NAME / MONGODB_USER / MONGODB_PASS while keeping MONGO_HOST,
# MONGO_PORT and MONGO_PARAMETERS on the short prefix. The mix below is the
# chart's, not a typo — do not "normalise" it.
#
# MONGODB_URI is NOT a connection string. Despite templates/NOTES.txt:79-89
# describing a "full connection string" mode, no template implements one: the
# ConfigMap is a blind range over .Values.configmap, and the shipped default is
# the bare word "mongodb". It is the SCHEME, and the application assembles
#   {MONGODB_URI}://{MONGODB_USER}:{MONGODB_PASS}@{MONGO_HOST}:{MONGO_PORT}/{MONGODB_DB_NAME}?{MONGO_PARAMETERS}
# "mongodb" is the only correct value for DocumentDB: it publishes no SRV
# records, so "mongodb+srv" cannot resolve.
#
# These keys land in .Values.configmap, EXCEPT the password, which is not
# emitted at all. Merge accordingly:
#
#   configmap:
#     MONGODB_URI: ...
#
# NOT emitted here, on purpose:
#   MONGODB_DB_NAME — the chart default is "midaz-console"; DocumentDB creates a
#     database lazily on first write, so Terraform never creates it and must not
#     claim to know it. Leave the chart default alone.
#   MONGODB_PASS   — read from secret_name by External Secrets, never an output.
#     Note it is a `secrets:` key that the chart base64-encodes itself
#     (templates/secrets.yaml:11-13 uses b64enc over plain values), and it is NOT
#     wired to the mongodb subchart Secret — so it must be supplied explicitly
#     even when the subchart is on.
################################################################################

output "helm_values" {
  description = "product-console chart env vars this datastore fills in, ready to merge into .Values.configmap. Pair it with mongodb.enabled = false (values.yaml:270-271, default true) so the bundled Bitnami subchart is not deployed alongside DocumentDB."
  value = {
    MONGODB_URI      = "mongodb"
    MONGO_HOST       = module.documentdb.endpoint
    MONGO_PORT       = tostring(module.documentdb.port)
    MONGODB_USER     = var.master_username
    MONGO_PARAMETERS = local.mongo_parameters
  }
}
