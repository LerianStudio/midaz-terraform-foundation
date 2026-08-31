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
  # REDIS_HOST is "host:port", not a host.
  #
  # Confirmed in the reporter chart: values.yaml ships
  # REDIS_HOST: reporter-valkey.reporter.svc.cluster.local:6379 and there is NO
  # REDIS_PORT key anywhere in the chart. Emitting a bare hostname produces an
  # application that dials port 0.
  #
  # This is the one place reporter and midaz agree and fetcher does not: the
  # fetcher chart splits REDIS_HOST and REDIS_PORT. Read the chart, not the
  # sibling product.
  ##############################################################################
  redis_host_port = "${module.valkey.endpoint}:${module.valkey.port}"

  ##############################################################################
  # TLS is reported as REQUIRED, not as AVAILABLE.
  #
  # transit_encryption_mode = "preferred" means ElastiCache accepts TLS and
  # plaintext clients alike, and the reporter chart connects in plaintext by
  # default. Reporting "true" in that state would flip the application to a TLS
  # handshake it has no CA configuration for, so only "required" reports true.
  ##############################################################################
  redis_tls_required = var.transit_encryption_enabled && var.transit_encryption_mode == "required"
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
  description = "EKS cluster whose node security group was looked up. Should equal the cluster_name output of infra-base/eks. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to reporter."
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
  description = "ARN of the Secrets Manager secret holding the auth token: reporter-{env}-valkey/auth-token in dedicated mode, shared-{env}-valkey/auth-token in shared mode."
  value       = module.valkey.secret_arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret holding the auth token. The token exists whether or not ElastiCache enforces it; this is the value an External Secrets Operator ExternalSecret references once auth_token_enabled is true."
  value       = module.valkey.secret_name
}

output "identifier" {
  description = "ElastiCache replication group id: reporter-{environment}-valkey in dedicated mode, the resolved shared-{env}-valkey in shared mode."
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
# Verified against reporter-helm 3.2.0 (appVersion 2.3.0), values.yaml
# `common.configmap` (the "Redis Configs" block), rendered by
# templates/manager/configmap.yaml and templates/worker/configmap.yaml.
#
# The complete Redis surface of this chart is: REDIS_MASTER_NAME, REDIS_HOST,
# REDIS_DB, REDIS_PROTOCOL, REDIS_TLS, REDIS_CA_CERT, REDIS_SERVICE_ACCOUNT.
# There is NO REDIS_PORT and NO MULTI_TENANT_REDIS_* pair (midaz has the latter;
# reporter's multi-tenancy surface is MULTI_TENANT_ENABLED only).
#
# REDIS_TLS reflects whether TLS is REQUIRED, not whether it is available.
# transit_encryption_mode = "preferred" means ElastiCache accepts TLS and
# plaintext clients alike, and the chart connects in plaintext, so only
# "required" reports true.
#
# NOT emitted here, on purpose:
#   REDIS_PASSWORD       — DOES NOT EXIST in this chart. values.yaml states the
#     key is intentionally omitted because the bundled valkey runs with
#     auth.enabled = false. CONFIRMAR with the chart owners before setting
#     auth_token_enabled = true on the ElastiCache side: today there is no chart
#     key to carry the token, so enforcing it locks the application out.
#   REDIS_CA_CERT        — the ElastiCache CA bundle, not produced by Terraform.
#   REDIS_PROTOCOL       — the RESP version (chart default "3"), a client choice.
#   REDIS_MASTER_NAME    — a Sentinel master name. ElastiCache is not Sentinel;
#     the chart default (empty) is correct and Terraform has nothing to put here.
#   REDIS_SERVICE_ACCOUNT / GOOGLE_APPLICATION_CREDENTIALS — a GCP MemoryStore
#     IAM path that has no AWS equivalent.
################################################################################

output "helm_values" {
  description = "reporter chart env vars this datastore fills in, ready to merge into common.configmap. Pair it with valkey.enabled = false so the bundled subchart is not deployed alongside ElastiCache — the reporter chart ships valkey.enabled = true by DEFAULT."
  value = {
    REDIS_HOST = local.redis_host_port
    REDIS_TLS  = local.redis_tls_required ? "true" : "false"
    REDIS_DB   = tostring(var.redis_db_index)
  }
}
