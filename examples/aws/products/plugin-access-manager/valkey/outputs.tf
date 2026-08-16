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
# datastore — so a plain module.valkey.x reference is safe.
################################################################################

locals {
  ################################################################################
  # REDIS_TLS reflects whether TLS is REQUIRED, not whether it is available.
  #
  # transit_encryption_mode = "preferred" means ElastiCache accepts TLS and
  # plaintext clients alike. Reporting "true" in that state would flip both
  # components into a TLS handshake for which nothing distributes the
  # ElastiCache CA bundle — the chart has a REDIS_CA_CERT key and this
  # repository fills it from nowhere.
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
  description = "EKS cluster whose node security group was looked up. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to plugin-access-manager."
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
  description = "Raw AWS primary endpoint of the replication group. This is REDIS_HOST verbatim and it must stay BARE: the chart concatenates the port itself (templates/auth/configmap.yaml:24, templates/identity/configmap.yaml:54). In shared mode this is the primary endpoint of shared-{env}-valkey, resolved by name."
  value       = module.valkey.endpoint
}

output "port" {
  description = "Valkey port. This chart has a real REDIS_PORT key on both component ConfigMaps AND folds the same value into the rendered REDIS_HOST — see helm_values."
  value       = module.valkey.port
}

output "security_group_id" {
  description = "Security group protecting the replication group. Null in shared mode — ingress on the shared group is owned by products/shared-resources/valkey."
  value       = module.valkey.security_group_id
}

output "secret_arn" {
  description = "ARN of the Secrets Manager secret holding the auth token: plugin-access-manager-{env}-valkey/auth-token in dedicated mode, shared-{env}-valkey/auth-token in shared mode."
  value       = module.valkey.secret_arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret holding the auth token. The token exists whether or not ElastiCache enforces it. It is NOT usable as-is by this chart: see the REDIS_USER note in helm_values."
  value       = module.valkey.secret_name
}

output "identifier" {
  description = "ElastiCache replication group id: plugin-access-manager-{environment}-valkey in dedicated mode, the resolved shared-{env}-valkey in shared mode."
  value       = module.valkey.identifier
}

################################################################################
# Valkey specifics
################################################################################

output "reader_endpoint" {
  description = "Reader endpoint of the replication group. Empty when the group has a single cache cluster. Neither component has a reader variable, so nothing consumes this today."
  value       = module.valkey.reader_endpoint
}

output "engine_version_actual" {
  description = "Running version of the cache engine. Null in shared mode."
  value       = module.valkey.engine_version_actual
}

output "auth_token_enabled" {
  description = "Whether ElastiCache is ENFORCING the auth token stored in secret_name. False means the token exists but is not required — which is the only workable setting while the chart sends REDIS_USER."
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
# Verified against chart plugin-access-manager 8.6.0 (appVersion 3.1.0),
# templates/auth/configmap.yaml lines 24-37, templates/identity/configmap.yaml
# lines 54-67, values.yaml lines 292-294.
#
# MERGE THIS MAP INTO **BOTH** `identity.configmap` AND `auth.configmap`.
# The two components carry independent, identically named REDIS_* keys and read
# the cache separately. Setting one and not the other leaves the second pointed
# at the in-cluster default plugin-access-manager-valkey-primary. The
# auth-backend (Casdoor) component has no Redis variables at all.
#
# ============================================================================
# THE HOST MUST BE BARE. THE CHART APPENDS THE PORT ITSELF.
# ============================================================================
# Both ConfigMap templates render the key as
#
#     printf "%s:%s" <REDIS_HOST value> <REDIS_PORT value>
#
# (templates/auth/configmap.yaml:24, templates/identity/configmap.yaml:54). The
# values key is a HOSTNAME; the rendered env var is "host:port". Passing
# "my-cache:6379" into values therefore produces "my-cache:6379:6379" in the
# ConfigMap and a client that cannot resolve anything.
#
# This is the exact OPPOSITE of the midaz chart, where REDIS_PORT was deleted in
# chart 3.0 and REDIS_HOST must already carry "host:port", and of the
# br-consignado-gw chart, which does the same. Three Lerian charts, three
# behaviours behind one variable name. Check the template before copying a
# helm_values block between products.
#
# Values are strings because they end up in a ConfigMap.
#
# NOT emitted here, on purpose:
#   REDIS_PASSWORD — read from secret_name by External Secrets, never an output.
#     Present on both components (templates/auth/secrets.yaml:12 and the
#     identity equivalent, values.yaml:307).
#   REDIS_USER — # CONFIRMAR no chart: whether the application can be run with
#     REDIS_USER unset/empty. The chart defaults it to "auth" on the auth
#     component (values.yaml:294) and "identity" on the identity component, but
#     ElastiCache auth tokens are the LEGACY password-only AUTH, which has no
#     username at all. A client that sends AUTH <user> <token> against a
#     token-protected replication group is rejected. Terraform cannot emit a
#     correct value here: with auth_token_enabled = false there is no user to
#     name, and with it true the correct answer requires ElastiCache RBAC users,
#     which _modules/valkey-elasticache does not create. Left to the operator,
#     deliberately, rather than guessed.
#   REDIS_CA_CERT — the ElastiCache CA bundle, distributed with the chart or
#     mounted from a ConfigMap, not produced by Terraform.
#   REDIS_MASTER_NAME — a Redis Sentinel master name. ElastiCache replication
#     groups are not Sentinel; the primary endpoint above is the failover-aware
#     address and there is no Sentinel service to name. Leave it at the chart
#     default.
#   REDIS_DB, REDIS_PROTOCOL, REDIS_SCAN_COUNT, REDIS_TOKEN_LIFETIME,
#     REDIS_TOKEN_REFRESH_DURATION — application tuning. Every Valkey node
#     exposes 16 logical databases and Terraform creates none of them; the rest
#     describe token behaviour, not the cache. Left at the chart defaults.
#   REDIS_USE_GCP_IAM, REDIS_SERVICE_ACCOUNT, GOOGLE_APPLICATION_CREDENTIALS —
#     a Google Cloud Memorystore IAM path. Not applicable on AWS.
################################################################################

output "helm_values" {
  description = "plugin-access-manager chart env vars this datastore fills in. Merge into BOTH identity.configmap AND auth.configmap. REDIS_HOST is a BARE hostname — the chart appends REDIS_PORT to it when rendering. Pair with valkey.enabled = false (values.yaml:445) so the bundled Bitnami subchart is not deployed alongside ElastiCache."
  value = {
    REDIS_HOST = module.valkey.endpoint
    REDIS_PORT = tostring(module.valkey.port)
    REDIS_TLS  = local.redis_tls_required ? "true" : "false"
  }
}
