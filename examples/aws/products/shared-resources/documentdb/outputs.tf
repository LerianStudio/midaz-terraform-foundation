################################################################################
# Outputs
#
# The seven uniform contract names (mode, endpoint, port, security_group_id,
# secret_arn, secret_name, identifier) are passed straight through from the
# module, so an operator script reads this stack the same way regardless of
# which datastore it wraps.
#
# There is no dns_name output and no private zone: DocumentDB presents a
# certificate for *.docdb.amazonaws.com, so a CNAME in front of it breaks TLS
# hostname verification. `endpoint` is the raw AWS host.
#
# There is no `documentdb_enabled` output any more. It existed when this tier
# was one root with five toggles; enablement is now "this directory was applied".
#
# The module is NOT under count here — this root wraps exactly one datastore —
# so a plain module.documentdb.x reference is safe.
#
# Products do NOT read this state with terraform_remote_state. They resolve the
# shared tier by NAME — data "aws_rds_cluster" on shared-{env}-docdb plus the
# Secrets Manager entry.
################################################################################

locals {
  ################################################################################
  # Connection-string parameters that are properties of DocumentDB itself, not
  # client preferences:
  #
  #   retryWrites=false  DocumentDB does not implement retryable writes. Drivers
  #                      default them ON, so omitting this makes every write fail.
  #   tls=true           mirrors the cluster `tls` parameter. Pair it with
  #                      MONGO_*_TLS_CA_CERT in the chart (the global RDS CA
  #                      bundle), which Terraform does not distribute.
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
  description = "EKS cluster whose node security group was looked up. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to this tier."
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
  description = "Provisioning mode the module ran in. Always \"dedicated\" here: this stack CREATES the shared cluster. Products consume it with mode = \"shared\" — see the header of main.tf."
  value       = module.documentdb.mode
}

output "endpoint" {
  description = "Raw AWS writer endpoint of the shared cluster — the MONGO host every consuming release connects to, with TLS on or off."
  value       = module.documentdb.endpoint
}

output "port" {
  description = "Port the cluster listens on."
  value       = module.documentdb.port
}

output "security_group_id" {
  description = "Security group protecting the shared cluster. This stack owns its ingress; a product consuming with mode = \"shared\" gets null from its own module."
  value       = module.documentdb.security_group_id
}

output "secret_arn" {
  description = "ARN of shared-{environment}-docdb/password."
  value       = module.documentdb.secret_arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret holding the master password. This is the exact name mongodb-documentdb resolves in shared mode, and the value an External Secrets Operator ExternalSecret references."
  value       = module.documentdb.secret_name
}

output "identifier" {
  description = "DocumentDB cluster identifier, shared-{environment}-docdb. This is the name a shared consumer resolves with data \"aws_rds_cluster\"."
  value       = module.documentdb.identifier
}

################################################################################
# DocumentDB specifics
################################################################################

output "reader_endpoint" {
  description = "Raw AWS reader endpoint of the shared cluster, for read-only consumers. Points at the writer while instances_count is 1."
  value       = module.documentdb.reader_endpoint
}

output "arn" {
  description = "ARN of the DocumentDB cluster."
  value       = module.documentdb.arn
}

output "kms_key_arn" {
  description = "ARN of the CMK encrypting the cluster storage."
  value       = module.documentdb.kms_key_arn
}

output "master_username" {
  description = "Master username configured on the cluster. Read from the stack variable rather than from the module output, which is marked sensitive and would redact anything it is merged into."
  value       = var.master_username
}

output "tls_enabled" {
  description = "Whether the cluster `tls` parameter is enabled. It does not change which host helm_values emits — that is always the raw endpoint — only whether MONGO_*_PARAMETERS carries tls=true."
  value       = var.documentdb_tls == "enabled"
}

################################################################################
# Helm handoff
#
# SCOPE WARNING. These are the env var names of the midaz chart, verified
# against chart 8.7.0 (appVersion 3.8.0), templates/ledger/configmap.yaml and
# templates/crm/configmap.yaml. This tier is consumed by ANY product, and
# products/midaz/README.md is explicit that other Lerian charts must not be
# assumed to use the same names. The FACTS below — host, port, user, the
# mandatory retryWrites=false — are tier-level and identical for every consumer;
# only the variable names are midaz's.
#
# MONGO_*_URI is NOT a connection string. The chart uses it for the SCHEME alone
# and the application assembles the URI from the HOST/PORT/USER/NAME variables
# around it. "mongodb" is the only correct value for DocumentDB: it publishes no
# SRV records, so "mongodb+srv" cannot resolve.
#
# NOT emitted here, on purpose:
#   MONGO_*_NAME     — DocumentDB creates a database lazily on first write, so
#     Terraform never creates them and must not claim to know them. On a shared
#     cluster each product picks its own.
#   MONGO_*_PASSWORD — read from secret_name by External Secrets.
#   MONGO_*_TLS_CA_CERT — the global RDS CA bundle, distributed with the chart.
#
# The unsuffixed MONGO_HOST / MONGO_PORT / MONGO_USER / MONGO_URI block is what
# midaz's CRM deployment reads. Harmless when CRM is off.
################################################################################

output "helm_values" {
  description = "Chart env vars this datastore fills in (midaz naming — see the header), ready to merge into ledger.configmap (and crm.configmap for the unsuffixed keys). Pair it with mongodb.enabled = false and mongodb.external = true so the bundled Bitnami subchart is not deployed alongside DocumentDB."
  value = {
    MONGO_ONBOARDING_URI        = "mongodb"
    MONGO_ONBOARDING_HOST       = module.documentdb.endpoint
    MONGO_ONBOARDING_PORT       = tostring(module.documentdb.port)
    MONGO_ONBOARDING_USER       = var.master_username
    MONGO_ONBOARDING_PARAMETERS = local.mongo_parameters

    MONGO_TRANSACTION_URI        = "mongodb"
    MONGO_TRANSACTION_HOST       = module.documentdb.endpoint
    MONGO_TRANSACTION_PORT       = tostring(module.documentdb.port)
    MONGO_TRANSACTION_USER       = var.master_username
    MONGO_TRANSACTION_PARAMETERS = local.mongo_parameters

    # crm.configmap — only rendered when crm.enabled is true.
    MONGO_URI        = "mongodb"
    MONGO_HOST       = module.documentdb.endpoint
    MONGO_PORT       = tostring(module.documentdb.port)
    MONGO_USER       = var.master_username
    MONGO_PARAMETERS = local.mongo_parameters
  }
}
