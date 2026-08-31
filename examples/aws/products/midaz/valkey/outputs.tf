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
  # The midaz chart REMOVED the REDIS_PORT variable in chart 3.0 and requires the
  # port to be embedded in REDIS_HOST (docs/UPGRADE-3.0.md: "Its value must now be
  # included directly in the REDIS_HOST variable as <host>:<port>"). Emitting a
  # bare hostname here produces a ledger that dials port 0.
  #
  # The multi-tenant variables are the exception and stay split — see helm_values.
  ################################################################################
  redis_host_port = "${module.valkey.endpoint}:${module.valkey.port}"

  ################################################################################
  # REDIS_TLS reflects whether TLS is REQUIRED, not whether it is available.
  #
  # transit_encryption_mode = "preferred" means ElastiCache accepts TLS and
  # plaintext clients alike, and the midaz chart currently connects in plaintext.
  # Reporting "true" in that state would flip the ledger to a TLS handshake it has
  # no CA configuration for, so only "required" is reported as true.
  ################################################################################
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
  description = "EKS cluster whose node security group was looked up. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to midaz."
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
  description = "ARN of the Secrets Manager secret holding the auth token: midaz-{env}-valkey/auth-token in dedicated mode, shared-{env}-valkey/auth-token in shared mode."
  value       = module.valkey.secret_arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret holding the auth token. The token exists whether or not ElastiCache enforces it; this is the value an External Secrets Operator ExternalSecret references to populate REDIS_PASSWORD once auth_token_enabled is true."
  value       = module.valkey.secret_name
}

output "identifier" {
  description = "ElastiCache replication group id: midaz-{environment}-valkey in dedicated mode, the resolved shared-{env}-valkey in shared mode."
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
  description = "Whether in-transit encryption is enabled on the replication group. Available is not the same as required — see transit_encryption_mode and the REDIS_TLS value in helm_values."
  value       = module.valkey.transit_encryption_enabled
}

output "subnet_group_name" {
  description = "Name of the cache subnet group. Null in shared mode."
  value       = module.valkey.subnet_group_name
}

################################################################################
# Helm handoff
#
# The exact env var names the midaz chart reads, so wiring the release is a copy,
# not a translation. Verified against chart 8.7.0 (appVersion 3.8.0),
# templates/ledger/configmap.yaml.
#
# KEYED BY CHART COMPONENT: the chart gives each component its own ConfigMap, so the
# destination is part of this output. Everything here lands on the LEDGER deployment
# — the CRM deployment has no Redis variables at all, which is why there is no "crm"
# entry rather than an empty one.
#
# The same shape is produced by pkg/infra/chartmap.go for shared mode. The two must
# agree: TestMidazShapeIsTheSameInBothModes fails when they drift.
#
# Two shapes that look like mistakes and are not:
#   REDIS_HOST carries "host:port" — the chart dropped REDIS_PORT in 3.0.
#   MULTI_TENANT_REDIS_HOST / MULTI_TENANT_REDIS_PORT are split, unlike the pair
#     above. Those two are only rendered when MULTI_TENANT_ENABLED is "true";
#     they are emitted here so enabling multi-tenancy needs no second lookup.
#
# NOT emitted here, on purpose:
#   REDIS_PASSWORD — read from secret_name by External Secrets, never an output.
#   REDIS_CA_CERT  — the ElastiCache CA bundle, distributed with the chart or
#     mounted from a ConfigMap, not produced by Terraform.
#   REDIS_USER / REDIS_USERNAME — do not exist in the chart, in any form.
################################################################################

output "helm_values" {
  description = "midaz chart env vars this datastore fills in, keyed by CHART COMPONENT. Merge each entry into the matching <component>.configmap block. `crm` is absent because the CRM deployment has no Redis variable at all. Pair it with valkey.enabled = false and valkey.external = true so the bundled Bitnami subchart is not deployed alongside ElastiCache."
  value = {
    ledger = {
      REDIS_HOST = local.redis_host_port
      REDIS_TLS  = local.redis_tls_required ? "true" : "false"
      REDIS_DB   = tostring(var.redis_db_index)

      MULTI_TENANT_REDIS_HOST = module.valkey.endpoint
      MULTI_TENANT_REDIS_PORT = tostring(module.valkey.port)
      MULTI_TENANT_REDIS_TLS  = local.redis_tls_required ? "true" : "false"
    }
  }
}
