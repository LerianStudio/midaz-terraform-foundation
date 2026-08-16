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
# datastore — so a plain module.postgres.x reference is safe. The one(...)
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
  description = "tag:Name of the VPC the instance was placed in, as derived or overridden. Should equal the vpc_name output of infra-base/vpc."
  value       = module.network.vpc_name
}

output "eks_cluster_name" {
  description = "EKS cluster whose node security group was looked up. Should equal the cluster_name output of infra-base/eks. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to plugin-br-pix-indirect-btg."
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
  description = "Raw AWS hostname of the instance — the database host the Helm release connects to. In shared mode this is the hostname of shared-{env}-postgres, resolved by name."
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
  description = "ARN of the Secrets Manager secret holding the master credentials: plugin-br-pix-indirect-btg-{env}-postgres/password in dedicated mode, shared-{env}-postgres/password in shared mode."
  value       = module.postgres.secret_arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret holding the master credentials. This is the value an External Secrets Operator ExternalSecret references."
  value       = module.postgres.secret_name
}

output "identifier" {
  description = "RDS DB instance identifier: plugin-br-pix-indirect-btg-{environment}-postgres in dedicated mode, the resolved shared-{env}-postgres in shared mode."
  value       = module.postgres.identifier
}

################################################################################
# PostgreSQL specifics
################################################################################

output "database_name" {
  description = "Name of the initial database RDS created, emitted as DB_NAME for all four data-plane components. The chart itself is inconsistent about this name (pix/inbound/outbound default to \"pix\", reconciliation to \"pix_btg\", the bundled subchart provisions \"pix_btg\"); RDS creates one database, and this is it."
  value       = module.postgres.database_name
}

output "username" {
  description = "Master username. Feeds DB_USER and DB_REPLICA_USER on all four data-plane components."
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

locals {
  ################################################################################
  # The replica keys are ALWAYS emitted, pointed at the primary when there is no
  # replica.
  #
  # This follows the chart, which defaults DB_REPLICA_HOST to the same
  # postgresHost helper as DB_HOST on all four data-plane components — "no
  # replica" is expressed by pointing the read pool at the writer, not by leaving
  # the keys unset. It is the midaz shape.
  #
  # It is also the OPPOSITE of the sibling product plugin-br-bank-transfer, whose
  # chart gates its whole POSTGRES_REPLICA_* block on the host being set. Two
  # plugins, two conventions.
  #
  # Leaving them unset here would be actively wrong on the external path: the
  # postgresHost helper returns EMPTY when the bundled subchart is disabled, and
  # only DB_HOST has a required() guard — DB_REPLICA_HOST would silently render
  # as "".
  #
  # replica_endpoint is null when no replica was created AND in shared mode.
  ################################################################################
  replica_host = coalesce(module.postgres.replica_endpoint, module.postgres.endpoint)

  ################################################################################
  # Every data-plane component takes the same four primary keys and the same four
  # replica keys. Only `schedule` takes none — it has no datastore configuration
  # at all (templates/schedule/configmap.yaml carries no DB_, REDIS_ or MONGO_
  # key).
  ################################################################################
  db_values = {
    DB_HOST = module.postgres.endpoint
    DB_PORT = tostring(module.postgres.port)
    DB_USER = module.postgres.username
    DB_NAME = module.postgres.database_name

    DB_REPLICA_HOST = local.replica_host
    DB_REPLICA_PORT = tostring(module.postgres.port)
    DB_REPLICA_USER = module.postgres.username
    DB_REPLICA_NAME = module.postgres.database_name
  }
}

################################################################################
# Helm handoff
#
# Verified against chart 3.8.0 (appVersion 1.9.1),
# templates/{pix,inbound,outbound,reconciliation}/configmap.yaml and
# templates/_helpers.tpl.
#
# THIS CHART USES DB_*, NOT POSTGRES_*. Four Lerian charts, three prefixes:
#   plugin-br-pix-indirect-btg   DB_HOST      DB_PORT  DB_USER  DB_NAME
#   plugin-br-bank-transfer      POSTGRES_HOST POSTGRES_PORT POSTGRES_USER POSTGRES_DB
#   notifications                POSTGRES_HOST POSTGRES_PORT POSTGRES_USER POSTGRES_NAME
#   midaz                        DB_ONBOARDING_HOST / DB_TRANSACTION_HOST ...
#
# FIVE COMPONENTS, FIVE ConfigMaps. helm_values is keyed by component because the
# chart is: there is no shared ConfigMap to merge into. `schedule` is absent from
# the map because its ConfigMap carries no datastore keys at all.
#
# DB_HOST IS REQUIRED ON THE EXTERNAL PATH. _helpers.tpl carries
# "plugin-br-pix-indirect-btg.dbHostRequired", which fail()s per component with
# "<component>.configmap.DB_HOST is REQUIRED when the bundled postgresql subchart
# is disabled or external". So this map is not a convenience — the release will
# not render without it.
#
# PAIR IT WITH:
#     postgresql:
#       enabled: false
#
# NOT emitted here, on purpose:
#   DB_PASSWORD — read from secret_name by External Secrets, never an output.
#     Note the chart fail()s per component when the subchart is external and
#     <component>.secrets.DB_PASSWORD is unset, so it has to be wired before the
#     first release.
#   REPLICATION_PASSWORD — a bundled-subchart streaming-replication credential
#     (pix/secrets.yaml). An RDS read replica does not use it.
#   DB_SSL_MODE — a client policy decision, not an infrastructure fact. The chart
#     default is "disable", which RDS accepts; tighten it in the chart when the
#     plugin is ready to validate certificates.
#   DB_MAX_OPEN_CONNS / DB_MAX_IDLE_CONNS — application configuration.
################################################################################

output "helm_values" {
  description = "plugin-br-pix-indirect-btg chart env vars this datastore fills in, keyed by CHART COMPONENT. Merge each entry into the matching <component>.configmap block — the chart gives every component its own ConfigMap. `schedule` is absent because it has no datastore keys. Pair it with postgresql.enabled = false so the bundled Bitnami subchart is not deployed alongside RDS."
  value = {
    pix            = local.db_values
    inbound        = local.db_values
    outbound       = local.db_values
    reconciliation = local.db_values
  }
}
