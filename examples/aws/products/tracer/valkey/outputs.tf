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
  # MULTI_TENANT_REDIS_TLS reflects whether TLS is REQUIRED, not whether it is
  # available.
  #
  # transit_encryption_mode = "preferred" means ElastiCache accepts TLS and
  # plaintext clients alike. Reporting "true" in that state would tell the
  # registry to open a TLS handshake it has no CA configuration for, so only
  # "required" is reported as true.
  #
  # The tracer chart's own default for this key is "true" (values.yaml:251).
  # That default describes an expectation, not the server; this value describes
  # what the server actually enforces, and is the one to wire.
  ################################################################################
  redis_tls_required = var.transit_encryption_enabled && var.transit_encryption_mode == "required"
}

################################################################################
# Cross-stack context (assert the derived strings without opening the tfvars)
################################################################################

output "vpc_name" {
  description = "tag:Name of the VPC the replication group was placed in, as derived or overridden. Should equal the vpc_name output of infra-base/vpc."
  value       = module.network.vpc_name
}

output "eks_cluster_name" {
  description = "EKS cluster whose node security group was looked up. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to tracer."
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
  description = "Raw AWS primary endpoint of the replication group — MULTI_TENANT_REDIS_HOST verbatim. The tracer chart wants this BARE, with the port in its own variable. In shared mode this is the primary endpoint of shared-{env}-valkey, resolved by name."
  value       = module.valkey.endpoint
}

output "port" {
  description = "Valkey port. The tracer chart has a real MULTI_TENANT_REDIS_PORT variable (templates/configmap.yaml:63), unlike the midaz chart which folds the port into REDIS_HOST."
  value       = module.valkey.port
}

output "security_group_id" {
  description = "Security group protecting the replication group. Null in shared mode — ingress on the shared group is owned by products/shared-resources/valkey."
  value       = module.valkey.security_group_id
}

output "secret_arn" {
  description = "ARN of the Secrets Manager secret holding the auth token: tracer-{env}-valkey/auth-token in dedicated mode, shared-{env}-valkey/auth-token in shared mode."
  value       = module.valkey.secret_arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret holding the auth token. The token exists whether or not ElastiCache enforces it; this is the value an External Secrets Operator ExternalSecret references to populate the chart's optional MULTI_TENANT_REDIS_PASSWORD once auth_token_enabled is true."
  value       = module.valkey.secret_name
}

output "identifier" {
  description = "ElastiCache replication group id: tracer-{environment}-valkey in dedicated mode, the resolved shared-{env}-valkey in shared mode."
  value       = module.valkey.identifier
}

################################################################################
# Valkey specifics
################################################################################

output "reader_endpoint" {
  description = "Reader endpoint of the replication group. Empty when the group has a single cache cluster. The tracer chart has no reader variable, so nothing consumes this today."
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
  description = "Whether in-transit encryption is enabled on the replication group. Available is not the same as required — see transit_encryption_mode and the MULTI_TENANT_REDIS_TLS value in helm_values."
  value       = module.valkey.transit_encryption_enabled
}

output "subnet_group_name" {
  description = "Name of the cache subnet group. Null in shared mode."
  value       = module.valkey.subnet_group_name
}

################################################################################
# Helm handoff
#
# Verified against chart tracer-helm 2.1.0 (appVersion 1.0.0),
# templates/configmap.yaml lines 58-77 and values.yaml lines 245-251.
#
# THE TRACER CHART HAS NO PLAIN REDIS_HOST AND NO PLAIN REDIS_PORT. Grepping
# REDIS across the whole chart returns MULTI_TENANT_REDIS_* and nothing else.
# The cache is used for exactly one thing: the multi-tenant connection-pool
# registry. Every key below is rendered ONLY inside the
# `MULTI_TENANT_ENABLED == "true"` branch of templates/configmap.yaml, so with
# multi-tenancy off this whole map is inert — which is also why this root stack
# is opt-in and should simply not be applied in that case.
#
# THE HOST IS BARE. MULTI_TENANT_REDIS_HOST takes a hostname and
# MULTI_TENANT_REDIS_PORT takes the port, as two separate keys
# (templates/configmap.yaml:62-63; the values.yaml comments at 245-248 spell out
# the split). This is the OPPOSITE of the midaz chart, where REDIS_PORT was
# removed in chart 3.0 and REDIS_HOST must carry "host:port" in one string.
# Concatenating here would produce a registry that dials a hostname containing a
# colon.
#
# Values are strings because they end up in a ConfigMap.
#
# NOT emitted here, on purpose:
#   MULTI_TENANT_REDIS_PASSWORD — read from secret_name by External Secrets,
#     never an output. It is optional in the chart, which states so explicitly
#     at templates/secrets.yaml:6 ("MULTI_TENANT_REDIS_PASSWORD is optional
#     (Redis without auth is allowed)").
#   MULTI_TENANT_ENABLED, MULTI_TENANT_URL, MULTI_TENANT_SERVICE_API_KEY and the
#     pool/circuit-breaker tuning keys (MAX_TENANT_POOLS, IDLE_TIMEOUT_SEC,
#     TIMEOUT, CIRCUIT_BREAKER_*, CACHE_TTL_SEC, CONNECTIONS_CHECK_INTERVAL_SEC,
#     MAX_OPEN_CONNS_PER_TENANT, MAX_IDLE_CONNS_PER_TENANT) — application
#     configuration and a control-plane URL, none of which this instance knows
#     anything about. MULTI_TENANT_URL is `required(...)` in the template and
#     will fail the render if left empty with multi-tenancy on; supply it in
#     values.
#   REDIS_HOST / REDIS_PORT / REDIS_TLS / REDIS_DB — DO NOT ADD THEM. They exist
#     in the midaz chart and NOT in this one; a key the chart does not read is
#     dead weight that looks like configuration.
################################################################################

output "helm_values" {
  description = "tracer chart env vars this datastore fills in, ready to merge into tracer.configmap. Only meaningful with MULTI_TENANT_ENABLED = \"true\" — the chart renders these keys nowhere else. The tracer chart declares no Valkey subchart (Chart.yaml has no dependencies block), so there is nothing to turn off."
  value = {
    MULTI_TENANT_REDIS_HOST = module.valkey.endpoint
    MULTI_TENANT_REDIS_PORT = tostring(module.valkey.port)
    MULTI_TENANT_REDIS_TLS  = local.redis_tls_required ? "true" : "false"
  }
}
