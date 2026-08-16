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
# datastore — so a plain module.documentdb.x reference is safe. The one(...)
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
  description = "tag:Name of the VPC the cluster was placed in, as derived or overridden. Should equal the vpc_name output of infra-base/vpc."
  value       = module.network.vpc_name
}

output "eks_cluster_name" {
  description = "EKS cluster whose node security group was looked up. Should equal the cluster_name output of infra-base/eks. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to plugin-br-bank-transfer."
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
  description = "Raw AWS writer endpoint of the cluster — the Mongo host the Helm release connects to, with TLS on or off. In shared mode this is the writer endpoint of shared-{env}-docdb, resolved by identifier."
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
  description = "ARN of the Secrets Manager secret holding the master password: plugin-br-bank-transfer-{env}-docdb/password in dedicated mode, shared-{env}-docdb/password in shared mode."
  value       = module.documentdb.secret_arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret holding the master password. This is the value an External Secrets Operator ExternalSecret references."
  value       = module.documentdb.secret_name
}

output "identifier" {
  description = "DocumentDB cluster identifier: plugin-br-bank-transfer-{environment}-docdb in dedicated mode, the resolved shared-{env}-docdb in shared mode."
  value       = module.documentdb.identifier
}

################################################################################
# DocumentDB specifics
################################################################################

output "reader_endpoint" {
  description = "Raw AWS reader endpoint of the cluster, for read-only consumers. Resolved from the shared cluster in shared mode. The chart has no read-only Mongo variable today, so this is published for operators rather than consumed by the release."
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
  description = "Whether the cluster `tls` parameter is enabled."
  value       = var.documentdb_tls == "enabled"
}

locals {
  ################################################################################
  # MONGO_URI is the ONLY connection variable this chart has.
  #
  # There is no MONGO_HOST and no MONGO_PORT anywhere in
  # templates/configmap.yaml — the plugin is URI-only, and the chart says so:
  # "the app is URI-only, so the URI is assembled here rather than embedding a
  # plaintext password in the Secret" (_helpers.tpl, bank-transfer.mongoEnv).
  #
  # THE PASSWORD IS NOT IN THIS STRING. $(MONGO_PASSWORD) is Kubernetes env
  # expansion, not Terraform interpolation ($ followed by a PARENTHESIS is a
  # literal to Terraform; only ${...} interpolates). The chart emits MONGO_URI as
  # an explicit env entry with a `value:`, immediately after a MONGO_PASSWORD
  # entry sourced with secretKeyRef — and the kubelet expands $(VAR) in env
  # values against earlier entries in the same list. So the credential travels
  # from Secrets Manager to the Secret to the container without ever passing
  # through Terraform state.
  #
  # That mechanism only works because MONGO_URI arrives as `env:`, not `envFrom:`
  # (envFrom values are never expanded). This is exactly the difference from the
  # RabbitMQ sibling of this product, where RABBITMQ_URL is delivered through
  # envFrom and therefore CANNOT use the same trick — see rabbitmq/outputs.tf.
  #
  # Two query parameters are properties of DocumentDB itself, not preferences:
  #
  #   retryWrites=false  DocumentDB does not implement retryable writes. Every
  #                      modern driver enables them by default, so omitting this
  #                      makes every write fail. The chart's own bundled-Mongo
  #                      URI does NOT carry it — correct there, fatal here.
  #   tls=true           mirrors the cluster `tls` parameter, appended only when
  #                      documentdb_tls = "enabled".
  ################################################################################
  mongo_query = join("&", compact([
    "authSource=${var.mongo_auth_source}",
    "retryWrites=false",
    var.documentdb_tls == "enabled" ? "tls=true" : "",
  ]))

  mongo_uri = format(
    "mongodb://%s:$(MONGO_PASSWORD)@%s:%s/?%s",
    var.master_username,
    module.documentdb.endpoint,
    tostring(module.documentdb.port),
    local.mongo_query,
  )
}

################################################################################
# Helm handoff
#
# Verified against chart 1.5.0 (appVersion 1.2.1), templates/secrets.yaml,
# templates/configmap.yaml and the "bank-transfer.mongoEnv" helper in
# templates/_helpers.tpl.
#
# THE EXTERNAL PATH IS A CLIFF, NOT A SLOPE. Read the helper before wiring this:
#
#   - With the bundled subchart, mongoEnv builds MONGO_URI itself from the
#     subchart Service name.
#   - With mongodb.enabled = false (or mongodb.external = true) and NO
#     bankTransfer.secrets.MONGO_URI, mongoEnv emits NO MONGO_URI ENV AT ALL.
#     The deployment renders cleanly and the plugin starts with no Mongo
#     connection string. There is no required() guarding it.
#
# So on the external path bankTransfer.secrets.MONGO_URI is effectively
# mandatory, and this output is the value it should hold.
# bankTransfer.secrets.MONGO_PASSWORD must be set too — it is what makes mongoEnv
# emit the MONGO_PASSWORD env that $(MONGO_PASSWORD) expands against.
#
# PAIR IT WITH BOTH SUBCHART SWITCHES:
#     mongodb:
#       enabled:  false
#       external: true
#
# NOT emitted here, on purpose:
#   MONGO_PASSWORD — read from secret_name by External Secrets, never an output.
#   MONGO_DATABASE — the chart default is "plugin_br_bank_transfer" and
#     DocumentDB creates a database lazily on first write, so Terraform never
#     creates it and must not claim to know it. (Note the chart is internally
#     inconsistent about this one: MONGO_DATABASE defaults to
#     "plugin_br_bank_transfer" while the bundled subchart provisions
#     "plugin_br_bank_transfer_jd". Neither is Terraform's to pick.)
#   MONGO_ENABLED — a feature flag, already "true" by default.
#   MONGO_TLS_CA_CERT — the global RDS CA bundle, distributed with the chart or
#     mounted from a ConfigMap, not produced by Terraform.
################################################################################

output "helm_values" {
  description = "Empty on purpose. This chart has no MONGO_HOST / MONGO_PORT keys in bankTransfer.configmap — the plugin is URI-only and the single connection variable lives in bankTransfer.secrets. See helm_secret_values."
  value       = {}
}

output "helm_secret_values" {
  description = "plugin-br-bank-transfer chart values this datastore fills in, for bankTransfer.secrets. MONGO_URI carries $(MONGO_PASSWORD) rather than a password: the chart emits it as an explicit env entry after a secretKeyRef-sourced MONGO_PASSWORD, and the kubelet expands it in the pod. Set bankTransfer.secrets.MONGO_PASSWORD from secret_name through External Secrets so the expansion has something to expand."
  value = {
    MONGO_URI = local.mongo_uri
  }
}

output "mongo_uri" {
  description = "The same MONGO_URI string, exported on its own so it can be asserted or templated without digging into a map."
  value       = local.mongo_uri
}
