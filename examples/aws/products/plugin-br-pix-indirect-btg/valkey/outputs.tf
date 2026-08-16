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
# datastore — so a plain module.valkey.x reference is safe. The one(...)
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
  description = "tag:Name of the VPC the replication group was placed in, as derived or overridden. Should equal the vpc_name output of infra-base/vpc."
  value       = module.network.vpc_name
}

output "eks_cluster_name" {
  description = "EKS cluster whose node security group was looked up. Should equal the cluster_name output of infra-base/eks. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to plugin-br-pix-indirect-btg."
  value       = module.network.eks_cluster_name
}

output "ingress_security_group_ids" {
  description = "Security groups authorised on the replication group. Empty before infra-base/eks exists unless allowed_security_group_ids was passed explicitly."
  value       = module.network.ingress_security_group_ids
}

output "ingress_cidr_blocks" {
  description = "CIDR blocks authorised on the replication group. Holds the Type=private subnet CIDRs while allow_private_subnet_cidr_ingress is true."
  value       = module.network.ingress_cidr_blocks
}

################################################################################
# Uniform datastore contract
################################################################################

output "mode" {
  description = "Provisioning mode this stack ran in: dedicated or shared."
  value       = module.valkey.mode
}

output "endpoint" {
  description = "Raw AWS primary endpoint of the replication group. It is the whole of REDIS_HOST for pix and outbound, and the host half of REDIS_HOST for reconciliation, which wants host:port in one string — see helm_values. In shared mode this is the primary endpoint of shared-{env}-valkey, resolved by name. It is the raw endpoint on purpose: with transit encryption on, the ElastiCache certificate only covers *.{cluster}.{region}.cache.amazonaws.com."
  value       = module.valkey.endpoint
}

output "port" {
  description = "Valkey port. Emitted as REDIS_PORT for pix and outbound; folded into REDIS_HOST for reconciliation, which has no REDIS_PORT key."
  value       = module.valkey.port
}

output "security_group_id" {
  description = "Security group protecting the replication group. Null in shared mode — ingress on the shared replication group is owned by products/shared-resources/valkey."
  value       = module.valkey.security_group_id
}

output "secret_arn" {
  description = "ARN of the Secrets Manager secret holding the auth token: plugin-br-pix-indirect-btg-{env}-valkey/auth-token in dedicated mode, shared-{env}-valkey/auth-token in shared mode."
  value       = module.valkey.secret_arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret holding the auth token. This is the value an External Secrets Operator ExternalSecret references."
  value       = module.valkey.secret_name
}

output "identifier" {
  description = "ElastiCache replication group id: plugin-br-pix-indirect-btg-{environment}-valkey in dedicated mode, the resolved shared-{env}-valkey in shared mode."
  value       = module.valkey.identifier
}

################################################################################
# Valkey specifics
################################################################################

output "reader_endpoint" {
  description = "Reader endpoint of the replication group. Resolved from the shared group in shared mode; empty when the group has a single cache cluster."
  value       = module.valkey.reader_endpoint
}

output "engine_version_actual" {
  description = "Running version of the cache engine. Null in shared mode."
  value       = module.valkey.engine_version_actual
}

output "auth_token_enabled" {
  description = "Whether ElastiCache is ENFORCING the auth token stored in secret_name. False means the token exists but is not required."
  value       = module.valkey.auth_token_enabled
}

output "transit_encryption_enabled" {
  description = "Whether in-transit encryption is enabled on the replication group. Available is not the same as required — see transit_encryption_mode."
  value       = module.valkey.transit_encryption_enabled
}

output "subnet_group_name" {
  description = "Name of the cache subnet group. Null in shared mode."
  value       = module.valkey.subnet_group_name
}

locals {
  ################################################################################
  # TWO SHAPES OF REDIS_HOST, INSIDE ONE CHART.
  #
  # This is not a copy of the midaz-versus-notifications difference. It is a
  # difference between COMPONENTS OF THE SAME CHART, and it is visible in the
  # defaults:
  #
  #   templates/pix/configmap.yaml
  #     REDIS_HOST: ... | default (include "...valkeyHost" .)
  #     REDIS_PORT: ... | default "6379"
  #
  #   templates/outbound/configmap.yaml    same as pix
  #
  #   templates/reconciliation/configmap.yaml
  #     REDIS_HOST: ... | default (printf "%s:6379" (include "...valkeyHost" .))
  #     (no REDIS_PORT key at all)
  #
  # So pix and outbound want a bare hostname plus a port, and reconciliation
  # wants them concatenated. Emitting one shape for all three breaks whichever
  # two it does not match. Reported as a chart finding; see the product README.
  ################################################################################
  redis_host_bare = module.valkey.endpoint
  redis_host_port = "${module.valkey.endpoint}:${module.valkey.port}"

  ################################################################################
  # REDIS_TLS reflects whether TLS is REQUIRED, not whether it is available.
  #
  # transit_encryption_mode = "preferred" means ElastiCache accepts TLS and
  # plaintext clients alike, and the plugin currently connects in plaintext.
  ################################################################################
  redis_tls_required = var.transit_encryption_enabled && var.transit_encryption_mode == "required"

  redis_common = {
    REDIS_DB  = tostring(var.redis_db_index)
    REDIS_TLS = local.redis_tls_required ? "true" : "false"
  }
}

################################################################################
# Helm handoff
#
# Verified against chart 3.8.0 (appVersion 1.9.1),
# templates/{pix,outbound,reconciliation}/configmap.yaml.
#
# THREE OF THE FIVE COMPONENTS SPEAK REDIS. inbound/configmap.yaml and
# schedule/configmap.yaml carry no REDIS_ key at all, so they are absent from the
# map below rather than present and empty.
#
# The two REDIS_HOST shapes are the reason this output is keyed by component and
# not flat. See the locals above.
#
# PAIR IT WITH:
#     valkey:
#       enabled: false
#
# NOT emitted here, on purpose:
#   REDIS_PASSWORD — read from secret_name by External Secrets, never an output.
#     _helpers.tpl states it "stays operator-provided" on every component.
#   REDIS_CA_CERT — the ElastiCache CA bundle, distributed with the chart or
#     mounted from a ConfigMap, not produced by Terraform.
#   REDIS_MASTER_NAME — a Sentinel construct. ElastiCache replication groups
#     expose no Sentinel, so the chart's empty default is correct.
#   REDIS_USE_GCP_IAM / REDIS_SERVICE_ACCOUNT / REDIS_TOKEN_LIFETIME /
#     REDIS_TOKEN_REFRESH_DURATION — Google Memorystore IAM authentication. This
#     is an AWS stack; the chart's defaults (false / empty) are correct here.
#   REDIS_USER — the chart defaults it to "plugin" on all three components, but
#     the module creates no ElastiCache RBAC user and the implicit ElastiCache
#     account is "default".
#     # CONFIRMAR no chart: whether the plugin sends REDIS_USER on an auth-token
#     # (non-RBAC) ElastiCache, and what it should be. Not emitted until
#     # confirmed — leaving the chart default in place is the honest state.
################################################################################

output "helm_values" {
  description = "plugin-br-pix-indirect-btg chart env vars this datastore fills in, keyed by CHART COMPONENT. Merge each entry into the matching <component>.configmap block. inbound and schedule are absent because they carry no REDIS_ keys. NOTE the deliberate difference between the entries: pix and outbound take a bare REDIS_HOST plus REDIS_PORT, reconciliation takes REDIS_HOST as host:port and has no REDIS_PORT key. Pair it with valkey.enabled = false so the bundled subchart is not deployed alongside ElastiCache."
  value = {
    pix = merge(local.redis_common, {
      REDIS_HOST = local.redis_host_bare
      REDIS_PORT = tostring(module.valkey.port)
    })
    outbound = merge(local.redis_common, {
      REDIS_HOST = local.redis_host_bare
      REDIS_PORT = tostring(module.valkey.port)
    })
    # No REDIS_PORT: this component's chart default folds the port into the host.
    reconciliation = merge(local.redis_common, {
      REDIS_HOST = local.redis_host_port
    })
  }
}
