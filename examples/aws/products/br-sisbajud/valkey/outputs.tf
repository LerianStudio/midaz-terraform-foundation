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
# datastore — so a plain module.valkey.x reference is safe. The one(...)
# gymnastics live inside the module, where the count actually is.
################################################################################

locals {
  ################################################################################
  # REDIS_HOST is "host:port", not a host.
  #
  # This is true in the br-sisbajud chart for a completely different reason than in
  # midaz. There is no removed REDIS_PORT here — the variable never existed. The
  # chart's own in-cluster fallback renders REDIS_HOST as
  # "<svc>.<ns>.svc.cluster.local.:6379" (templates/configmap.yaml:8), the
  # values-template comments the key as "managed Valkey host:port"
  # (values-template.yaml:18), and the app's wait-for-dependencies initContainer
  # SPLITS the value on ":" to get host and port back
  # (templates/deployment.yaml:66-68), defaulting to 6379 only when the split
  # finds nothing after the colon.
  #
  # So a bare hostname does not fail loudly: the initContainer silently probes
  # 6379 and the application gets a host with no port.
  ################################################################################
  redis_host_port = "${module.valkey.endpoint}:${module.valkey.port}"
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
  description = "EKS cluster whose node security group was looked up. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to br-sisbajud."
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
  description = "Raw AWS primary endpoint of the replication group — the host half of REDIS_HOST. In shared mode this is the primary endpoint of shared-{env}-valkey, resolved by name. It is the raw endpoint on purpose: with transit encryption on, the ElastiCache certificate only covers *.{cluster}.{region}.cache.amazonaws.com."
  value       = module.valkey.endpoint
}

output "port" {
  description = "Valkey port. The chart has no REDIS_PORT variable — see helm_values."
  value       = module.valkey.port
}

output "security_group_id" {
  description = "Security group protecting the replication group. Null in shared mode — ingress on the shared group is owned by products/shared-resources/valkey."
  value       = module.valkey.security_group_id
}

output "secret_arn" {
  description = "ARN of the Secrets Manager secret holding the auth token: br-sisbajud-{env}-valkey/auth-token in dedicated mode, shared-{env}-valkey/auth-token in shared mode."
  value       = module.valkey.secret_arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret holding the auth token. The token exists whether or not ElastiCache enforces it; this is the value an External Secrets Operator ExternalSecret references to populate REDIS_PASSWORD once auth_token_enabled is true."
  value       = module.valkey.secret_name
}

output "identifier" {
  description = "ElastiCache replication group id: br-sisbajud-{environment}-valkey in dedicated mode, the resolved shared-{env}-valkey in shared mode."
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
  description = "Whether in-transit encryption is enabled on the replication group. Available is not the same as required, and the difference is not communicable to this chart: it defines no REDIS_TLS key, so the mode stays \"preferred\" and the client keeps speaking plaintext. See transit_encryption_mode."
  value       = module.valkey.transit_encryption_enabled
}

output "subnet_group_name" {
  description = "Name of the cache subnet group. Null in shared mode."
  value       = module.valkey.subnet_group_name
}

################################################################################
# Helm handoff
#
# The exact env var names the br-sisbajud chart reads, so wiring the release is a
# copy, not a translation. Verified against chart 1.1.0 (appVersion
# 1.0.0-beta.109):
#
#   values-template.yaml:18       REDIS_HOST, under brSisbajud.configmap,
#                                 commented "REQUIRED — managed Valkey host:port"
#   templates/configmap.yaml:10   REDIS_HOST is a RESERVED key the template writes
#                                 itself, so it must arrive through
#                                 brSisbajud.configmap.REDIS_HOST and nowhere else
#   templates/deployment.yaml:66  the initContainer splits REDIS_HOST on ":"
#   templates/secrets.yaml:20     REDIS_PASSWORD, under brSisbajud.secrets
#
# THIS CHART DEFINES EXACTLY TWO REDIS VARIABLES: REDIS_HOST and REDIS_PASSWORD.
# A grep over the whole chart returns nothing else. In particular, do NOT copy
# these from products/midaz/valkey — they are midaz-chart names and produce dead
# ConfigMap keys here:
#
#   REDIS_TLS                 does not exist
#   REDIS_DB                  does not exist
#   MULTI_TENANT_REDIS_HOST   does not exist
#   MULTI_TENANT_REDIS_PORT   does not exist
#   MULTI_TENANT_REDIS_TLS    does not exist
#
# The transit-encryption posture is therefore NOT communicable to this chart
# through a value. Keep transit_encryption_mode at "preferred" (see the tfvars):
# there is no key to tell the client to speak TLS, so "required" locks it out with
# nothing in the values to explain why.
#
# NOT emitted here, on purpose:
#   REDIS_PASSWORD — read from secret_name by External Secrets, never an output.
#     The chart's own comment marks it "set if the external Redis requires auth"
#     (values-template.yaml:29), which tracks auth_token_enabled below.
################################################################################

output "helm_values" {
  description = "br-sisbajud chart env vars this datastore fills in, ready to merge into brSisbajud.configmap. Exactly one key: the chart defines no other non-secret Redis variable. Pair it with valkey.enabled = false and valkey.external = true so the bundled Bitnami subchart is not deployed alongside ElastiCache."
  value = {
    REDIS_HOST = local.redis_host_port
  }
}
