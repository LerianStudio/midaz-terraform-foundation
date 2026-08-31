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
# replication group — so a plain module.valkey.x reference is safe. The
# one(...) gymnastics live inside the module, where the count actually is.
################################################################################

locals {
  ##############################################################################
  # CACHE_ADDR is "host:port" in one string, and it is not called REDIS_*.
  #
  # This chart names its cache variables CACHE_ADDR / CACHE_TTL_SEC /
  # CACHE_PASSWORD. There is no REDIS_HOST, no REDIS_PORT and no REDIS_DB
  # anywhere in it, so none of the midaz, reporter or fetcher mappings apply.
  #
  # The combined form is required, not a convenience: the init container in
  # templates/deployment.yaml splits it back apart with
  #   CACHE_HOST=$(echo "$CACHE_ADDR" | cut -d: -f1)
  #   CACHE_PORT=$(echo "$CACHE_ADDR" | cut -d: -f2)
  # so a bare hostname yields an empty CACHE_PORT and the dependency wait hangs
  # for its full five-minute timeout before the pod ever starts.
  ##############################################################################
  cache_addr = "${module.valkey.endpoint}:${module.valkey.port}"
}

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
  description = "EKS cluster whose node security group was looked up. Should equal the cluster_name output of infra-base/eks. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to plugin-bc-correios."
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
  description = "Raw AWS primary endpoint of the replication group. In shared mode this is the primary endpoint of shared-{env}-valkey, resolved by name. It is the raw endpoint on purpose: with transit encryption on, the ElastiCache certificate only covers *.{cluster}.{region}.cache.amazonaws.com."
  value       = module.valkey.endpoint
}

output "port" {
  description = "Valkey port."
  value       = module.valkey.port
}

output "security_group_id" {
  description = "Security group protecting the replication group. Null in shared mode — ingress on the shared one is owned by products/shared-resources/valkey."
  value       = module.valkey.security_group_id
}

output "secret_arn" {
  description = "ARN of the Secrets Manager secret holding the auth token: plugin-bc-correios-{env}-valkey/auth-token in dedicated mode, shared-{env}-valkey/auth-token in shared mode."
  value       = module.valkey.secret_arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret holding the auth token. The token exists whether or not ElastiCache enforces it; this is the value an External Secrets Operator ExternalSecret references once auth_token_enabled is true."
  value       = module.valkey.secret_name
}

output "identifier" {
  description = "ElastiCache replication group id: plugin-bc-correios-{environment}-valkey in dedicated mode, the resolved shared-{env}-valkey in shared mode."
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

################################################################################
# Helm handoff
#
# Verified against plugin-bc-correios-helm 2.2.0 (appVersion 1.2.0),
# templates/configmap.yaml (the "Cache (Valkey)" block) and
# templates/secrets.yaml.
#
# SETTING THIS KEY IS NOT OPTIONAL. templates/configmap.yaml renders
#
#   CACHE_ADDR: {{ ...CACHE_ADDR | default (printf "%s-primary:6379" ...) }}
#
# so leaving it empty does not mean "unset" — it means the in-cluster Valkey
# subchart service name. An external ElastiCache is only reached when CACHE_ADDR
# is set explicitly, which is what this output is for.
#
# NOT emitted here, on purpose:
#   CACHE_PASSWORD — read from secret_name by External Secrets. The key exists in
#     the chart, so auth_token_enabled = true is reachable once the
#     ExternalSecret is wired.
#   CACHE_TTL_SEC  — application cache lifetime (chart default 60). Not an
#     infrastructure fact; ElastiCache enforces no TTL of its own.
#
# There is no TLS key of any kind in this chart's cache surface, which is why
# transit_encryption_mode stays "preferred" — see the tfvars.
################################################################################

output "helm_values" {
  description = "plugin-bc-correios chart env vars this datastore fills in, ready to merge into the bc-correios.configmap block. Pair it with valkey.enabled = false and valkey.external = true. CACHE_ADDR must be set explicitly: the chart defaults it to the in-cluster subchart service rather than leaving it empty."
  value = {
    CACHE_ADDR = local.cache_addr
  }
}
