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
# datastore — so a plain module.documentdb.x reference is safe. The one(...)
# gymnastics live inside the module, where the count actually is.
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
  #                      bundle), which Terraform does not distribute. Safe now
  #                      that MONGO_*_HOST is the raw *.docdb.amazonaws.com
  #                      endpoint — the name the certificate actually covers.
  #
  # CONFIRMAR no chart: whether the ledger joins MONGO_*_PARAMETERS onto the
  # connection string with a leading "?" or expects one already present. The value
  # below carries no separator.
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
  description = "EKS cluster whose node security group was looked up. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to midaz."
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
  description = "Raw AWS writer endpoint of the cluster — the MONGO_*_HOST the Helm release connects to, with TLS on or off. In shared mode this is the writer endpoint of shared-{env}-docdb, resolved by identifier."
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
  description = "ARN of the Secrets Manager secret holding the master password: midaz-{env}-docdb/password in dedicated mode, shared-{env}-docdb/password in shared mode."
  value       = module.documentdb.secret_arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret holding the master password. This is the value an External Secrets Operator ExternalSecret references to populate MONGO_ONBOARDING_PASSWORD and MONGO_TRANSACTION_PASSWORD."
  value       = module.documentdb.secret_name
}

output "identifier" {
  description = "DocumentDB cluster identifier: midaz-{environment}-docdb in dedicated mode, the resolved shared-{env}-docdb in shared mode."
  value       = module.documentdb.identifier
}

################################################################################
# DocumentDB specifics
################################################################################

output "reader_endpoint" {
  description = "Raw AWS reader endpoint of the cluster, for read-only consumers. Resolved from the shared cluster in shared mode. The midaz chart has no read-only Mongo variable today, so this is published for operators rather than consumed by the release."
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
  description = "Master username configured on the cluster. It is the ADMIN identity, consumed by the chart's bootstrap Job as MONGO_ROOT_USER — not the user the workload authenticates as, which the Job creates. Read from the stack variable rather than from the module output, which is marked sensitive and would redact anything it is merged into."
  value       = var.master_username
}

output "tls_enabled" {
  description = "Whether the cluster `tls` parameter is enabled. It no longer changes which host helm_values emits — that is always the raw endpoint — only whether MONGO_*_PARAMETERS carries tls=true."
  value       = var.documentdb_tls == "enabled"
}

################################################################################
# Helm handoff
#
# The exact env var names the midaz chart reads, so wiring the release is a copy,
# not a translation. Verified against chart 8.7.0 (appVersion 3.8.0),
# templates/ledger/configmap.yaml.
#
# KEYED BY CHART COMPONENT, and this is the output where that matters most: the
# suffixed and unsuffixed Mongo keys differ only by prefix and go to two DIFFERENT
# ConfigMaps. Flattened into one map, that routing existed only in prose, and every
# consumer had to re-derive it from a comment.
#
# The ledger keys land on the LEDGER deployment. There is no separate onboarding and
# transaction deployment — the ledger container is unified and carries both sets of
# variables, pointed at the same cluster.
#
# The same shape is produced by pkg/infra/chartmap.go for shared mode. The two must
# agree: TestMidazShapeIsTheSameInBothModes fails when they drift.
#
# MONGO_ONBOARDING_URI / MONGO_TRANSACTION_URI are NOT connection strings. The
# chart uses them for the SCHEME alone and the application assembles the URI from
# the HOST/PORT/USER/NAME variables around it. "mongodb" is the only correct
# value for DocumentDB: it publishes no SRV records, so "mongodb+srv" cannot
# resolve.
#
# NOT emitted here, on purpose:
#   MONGO_*_NAME     — the chart defaults are "onboarding" and "transaction";
#     DocumentDB creates a database lazily on first write, so Terraform never
#     creates them and must not claim to know them.
#
# NO *_USER KEY IS EMITTED, and that is deliberate. The username above is the
# MASTER, and the workload does not authenticate as the master: the chart ships
# bootstrap Jobs (templates/bootstrap-postgres.yaml, bootstrap-mongodb.yaml,
# bootstrap-rabbitmq.yaml) that connect as the master, create a scoped user, and
# exit. The chart's own defaults for these keys are those scoped users — "midaz"
# for postgres and mongo, "transaction" for rabbitmq — so emitting the master here
# overrode a correct default with an identity whose password the release does not
# have. The master travels instead as the admin credential of the bootstrap Job,
# via `secret_name` below.
#
# NOT emitted here either, on purpose:
#   MONGO_*_PASSWORD — the application's password, chosen by whoever runs the
#     bootstrap Job. It is not in state and not in this secret, which holds the
#     master.
#   MONGO_*_TLS_CA_CERT — the global RDS CA bundle, distributed with the chart or
#     mounted from a ConfigMap, not produced by Terraform.
#
# CRM (crm.enabled, false by default) reads the UNSUFFIXED MONGO_HOST / MONGO_PORT
# / MONGO_USER / MONGO_URI instead — see templates/crm/configmap.yaml. They are
# emitted under the "crm" component below so turning CRM on does not need a second
# lookup; they are harmless when it is off.
################################################################################

output "helm_values" {
  description = "midaz chart env vars this datastore fills in, keyed by CHART COMPONENT. Merge each entry into the matching <component>.configmap block: the suffixed keys are read by templates/ledger/configmap.yaml and the unsuffixed ones by templates/crm/configmap.yaml. Pair it with mongodb.enabled = false and mongodb.external = true so the bundled Bitnami subchart is not deployed alongside DocumentDB."
  value = {
    ledger = {
      MONGO_ONBOARDING_URI        = "mongodb"
      MONGO_ONBOARDING_HOST       = module.documentdb.endpoint
      MONGO_ONBOARDING_PORT       = tostring(module.documentdb.port)
      MONGO_ONBOARDING_PARAMETERS = local.mongo_parameters

      MONGO_TRANSACTION_URI        = "mongodb"
      MONGO_TRANSACTION_HOST       = module.documentdb.endpoint
      MONGO_TRANSACTION_PORT       = tostring(module.documentdb.port)
      MONGO_TRANSACTION_PARAMETERS = local.mongo_parameters
    }

    # Only rendered when crm.enabled is true, and inert until then.
    crm = {
      MONGO_URI        = "mongodb"
      MONGO_HOST       = module.documentdb.endpoint
      MONGO_PORT       = tostring(module.documentdb.port)
      MONGO_PARAMETERS = local.mongo_parameters
    }
  }
}
