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
  description = "EKS cluster whose node security group was looked up. Should equal the cluster_name output of infra-base/eks. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to plugin-br-pix-indirect-btg."
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
  description = "ARN of the Secrets Manager secret holding the master password: plugin-br-pix-indirect-btg-{env}-docdb/password in dedicated mode, shared-{env}-docdb/password in shared mode."
  value       = module.documentdb.secret_arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret holding the master password. This is the value an External Secrets Operator ExternalSecret references."
  value       = module.documentdb.secret_name
}

output "identifier" {
  description = "DocumentDB cluster identifier: plugin-br-pix-indirect-btg-{environment}-docdb in dedicated mode, the resolved shared-{env}-docdb in shared mode."
  value       = module.documentdb.identifier
}

################################################################################
# DocumentDB specifics
################################################################################

output "reader_endpoint" {
  description = "Raw AWS reader endpoint of the cluster, for read-only consumers. Resolved from the shared cluster in shared mode. The chart has no read-only Mongo variable on any component, so this is published for operators rather than consumed by the release."
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
  # The three components that speak Mongo take the same four keys. Only `pix`
  # additionally has MONGO_TLS — inbound/configmap.yaml and
  # outbound/configmap.yaml have no such key, so setting it there would land in a
  # ConfigMap the application never reads. reconciliation and schedule have no
  # Mongo configuration at all.
  ################################################################################
  mongo_values = {
    # MONGO_URI is the SCHEME, not a connection string — the chart default is the
    # bare word "mongodb" and the application assembles the URI from the HOST /
    # PORT / USER / NAME variables around it. "mongodb" is the only correct value
    # for DocumentDB: it publishes no SRV records, so "mongodb+srv" cannot
    # resolve.
    MONGO_URI  = "mongodb"
    MONGO_HOST = module.documentdb.endpoint
    MONGO_PORT = tostring(module.documentdb.port)
    MONGO_USER = var.master_username
  }
}

################################################################################
# Helm handoff
#
# Verified against chart 3.8.0 (appVersion 1.9.1),
# templates/{pix,inbound,outbound}/configmap.yaml and templates/_helpers.tpl.
#
# MONGO_HOST IS REQUIRED ON THE EXTERNAL PATH. _helpers.tpl carries
# "plugin-br-pix-indirect-btg.mongoHostRequired", which fail()s per component
# with "<component>.configmap.MONGO_HOST is REQUIRED when the bundled mongodb
# subchart is disabled or external". This map is what satisfies it.
#
# This chart splits the connection into HOST / PORT / USER / NAME, which is the
# midaz shape. Its sibling plugin-br-bank-transfer is URI-only and takes a single
# MONGO_URI carrying everything — same company, same quarter, opposite designs.
#
# MONGO_TLS IS PIX-ONLY. templates/pix/configmap.yaml has it; inbound and
# outbound do not. That is why the pix entry below is a superset rather than the
# same map three times.
#
# PAIR IT WITH:
#     mongodb:
#       enabled: false
#
# NOT emitted here, on purpose:
#   MONGO_PASSWORD — read from secret_name by External Secrets, never an output.
#     The chart fail()s per component when the subchart is external and
#     <component>.secrets.MONGO_PASSWORD is unset, so it has to be wired before
#     the first release.
#   MONGO_NAME — the chart default is "pix-btg-db"; DocumentDB creates a database
#     lazily on first write, so Terraform never creates it and must not claim to
#     know it.
#   MONGO_MAX_POOL_SIZE — application configuration.
#
# ONE MORE THING THE BOOTSTRAP JOB DOES. templates/bootstrap-mongodb.yaml runs
# mongosh against the cluster with MONGO_ROOT_USER / MONGO_ROOT_PASSWORD and
# creates or updates an application user from MONGO_APP_USER / MONGO_APP_PASSWORD
# with roles from ROLES_JSON, against the admin database.
#   # CONFIRMAR com o time: whether that Job is expected to run against
#   # DocumentDB. DocumentDB implements a restricted subset of MongoDB's role
#   # model, so a ROLES_JSON written for the bundled Bitnami MongoDB may be
#   # rejected. Terraform creates the master user only; any application user is
#   # the Job's or an operator's to create.
################################################################################

output "helm_values" {
  description = "plugin-br-pix-indirect-btg chart env vars this datastore fills in, keyed by CHART COMPONENT. Merge each entry into the matching <component>.configmap block. reconciliation and schedule are absent because they have no Mongo keys; pix carries MONGO_TLS on top of the shared four because it is the only component that has that key. Pair it with mongodb.enabled = false so the bundled Bitnami subchart is not deployed alongside DocumentDB."
  value = {
    pix = merge(local.mongo_values, {
      MONGO_TLS = var.documentdb_tls == "enabled" ? "true" : "false"
    })
    inbound  = local.mongo_values
    outbound = local.mongo_values
  }
}
