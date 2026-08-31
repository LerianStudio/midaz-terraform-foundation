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
  # MONGO_URL template, with the password left as a literal placeholder.
  #
  # THE CHART'S OWN EXAMPLE IS WRONG FOR DOCUMENTDB, in a way that fails every
  # write rather than the connection. values-template.yaml:87 shows:
  #
  #     mongodb://user:<password>@mongo-host:27017/?authSource=admin
  #
  # Two query parameters are missing and both are properties of DocumentDB, not
  # client preferences:
  #
  #   retryWrites=false  DocumentDB does NOT implement retryable writes, and every
  #                      modern driver enables them BY DEFAULT. Omitting this makes
  #                      each write fail with an unsupported-command error — the
  #                      connection succeeds, so it looks like an application bug.
  #   tls=true           mirrors the cluster `tls` parameter. Only appended when
  #                      documentdb_tls = "enabled"; pair it with a mounted RDS CA
  #                      bundle, which Terraform does not distribute and the chart
  #                      has no key for.
  #
  # authSource=admin is kept: DocumentDB creates every user in admin, and the
  # chart's bootstrap Job authenticates the same way (--authenticationDatabase
  # admin, templates/bootstrap-mongodb.yaml).
  #
  # mongodb:// and not mongodb+srv:// — DocumentDB publishes no SRV records.
  ################################################################################
  mongo_parameters = join("&", compact([
    "authSource=admin",
    "retryWrites=false",
    var.documentdb_tls == "enabled" ? "tls=true" : "",
  ]))

  mongo_url_template = "mongodb://pixswitch:<password>@${module.documentdb.endpoint}:${module.documentdb.port}/?${local.mongo_parameters}"
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
  description = "EKS cluster whose node security group was looked up. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to plugin-br-pix-switch."
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
  description = "ARN of the Secrets Manager secret holding the master password: plugin-br-pix-switch-{env}-docdb/password in dedicated mode, shared-{env}-docdb/password in shared mode."
  value       = module.documentdb.secret_arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret holding the master password. This is the value an External Secrets Operator ExternalSecret references to populate MONGO_ONBOARDING_PASSWORD and MONGO_TRANSACTION_PASSWORD."
  value       = module.documentdb.secret_name
}

output "identifier" {
  description = "DocumentDB cluster identifier: plugin-br-pix-switch-{environment}-docdb in dedicated mode, the resolved shared-{env}-docdb in shared mode."
  value       = module.documentdb.identifier
}

################################################################################
# DocumentDB specifics
################################################################################

output "reader_endpoint" {
  description = "Raw AWS reader endpoint of the cluster, for read-only consumers. Resolved from the shared cluster in shared mode. The plugin-br-pix-switch chart has no read-only Mongo variable today, so this is published for operators rather than consumed by the release."
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
  description = "Whether the cluster `tls` parameter is enabled. It no longer changes which host helm_values emits — that is always the raw endpoint — only whether MONGO_*_PARAMETERS carries tls=true."
  value       = var.documentdb_tls == "enabled"
}

################################################################################
# Helm handoff
#
# READ THIS FIRST: THIS MAP IS HELM VALUE PATHS, NOT ENV VARS.
#
# Every other product here emits environment variable names. plugin-br-pix-switch
# reads Mongo through ONE key, on ONE component, and that key is a full
# connection URL living in a Secret. Verified against chart 2.0.0-beta.1+:
#
#   values-template.yaml:87   dictHub.secrets.MONGO_URL
#   values.yaml:1428-1451     "Used by dict-hub only for MONGO_URL"; the bundled
#                             Bitnami mongodb subchart ships disabled and the
#                             comment points at external Mongo/DocumentDB/Atlas
#   templates/dict-hub/secrets.yaml
#                             the secrets map is emitted verbatim; there is no
#                             host key, no port key and no user key
#
# TERRAFORM CANNOT FILL A SECRET. MONGO_URL carries the password, so it is
# published as the mongo_url_template output instead and the operator substitutes
# the application user's password.
#
# WHAT *IS* NON-SECRET, AND IS EMITTED BELOW: the chart's Mongo bootstrap Job
# reads host and port as plain values under global.externalMongoDefinitions
# (values.yaml:103-105), plus the root username it authenticates with
# (values.yaml:109).
#
# THE ROOT USERNAME IS A REAL TRAP. The chart defaults
# global.externalMongoDefinitions.mongoAdminLogin.username to "root"
# (values.yaml:109); the DocumentDB master username created here defaults to
# "docdbadmin". They must match or the bootstrap Job cannot authenticate. The key
# is emitted below so the Terraform value wins rather than the chart default.
#
# NOT emitted here, on purpose:
#   dictHub.secrets.MONGO_URL — a secret. See mongo_url_template.
#   dictHub.configmap.MONGO_DB_NAME — "pix-dict" (values-template.yaml:83). An
#     application decision; DocumentDB creates a database lazily on first write,
#     so Terraform neither creates it nor knows it.
#   mongoAdminLogin.password — the master password, read from secret_name by
#     External Secrets. Prefer mongoAdminLogin.useExistingSecret.name over an
#     inline value.
#   pixswitchCredentials.* — the APPLICATION user, created by the bootstrap Job
#     from a password the operator supplies. Not this credential.
#
# ONE MORE THING TO VERIFY IN A REAL ACCOUNT:
#
#   # CONFIRMAR: the Mongo bootstrap Job runs `mongosh --host --port` with no
#   # --tls flag (templates/bootstrap-mongodb.yaml). That works only while the
#   # cluster's tls parameter is "disabled", which is the default here and matches
#   # products/midaz/documentdb. Turning documentdb_tls on requires a chart change
#   # to that Job as well as a CA bundle for the application, so the two have to
#   # move together.
################################################################################

output "helm_values" {
  description = "plugin-br-pix-switch HELM VALUE PATHS (not env vars — see the header) that this datastore fills in: the Mongo bootstrap Job's connection host and port, and the root username it authenticates with. The dictHub MONGO_URL itself is a SECRET and is published as mongo_url_template instead. Pair with mongodb.enabled = false; the chart ships that default already."
  value = {
    "global.externalMongoDefinitions.connection.host"          = module.documentdb.endpoint
    "global.externalMongoDefinitions.connection.port"          = tostring(module.documentdb.port)
    "global.externalMongoDefinitions.mongoAdminLogin.username" = var.master_username
  }
}

output "mongo_url_template" {
  description = "dictHub.secrets.MONGO_URL template, with the password left as the literal placeholder <password>. Substitute the APPLICATION user's password (the one given to global.externalMongoDefinitions.pixswitchCredentials), NOT the master password behind secret_name. IT CARRIES retryWrites=false, WHICH THE CHART'S OWN EXAMPLE OMITS: DocumentDB does not implement retryable writes and every driver enables them by default, so without it each write fails while the connection succeeds."
  value       = local.mongo_url_template
}

output "mongo_parameters" {
  description = "The query string this stack appends to the Mongo connection URL: authSource=admin, retryWrites=false, and tls=true when documentdb_tls is enabled. Published separately so an operator assembling the URL by hand cannot drop retryWrites=false."
  value       = local.mongo_parameters
}
