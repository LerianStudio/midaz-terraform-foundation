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

################################################################################
# REDIS_TLS is emitted from transit_encryption_enabled, not from the MODE, and the
# distinction matters here in a way it does not for the other Valkey consumers.
#
# transit_encryption_mode = "preferred" means ElastiCache accepts TLS and plaintext
# clients alike. For most services this repository reports "false" in that state,
# because flipping them into a TLS handshake needs an ElastiCache CA bundle that
# nothing distributes.
#
# TENANT-MANAGER IS THE EXCEPTION: it takes REDIS_CA_CERT as BASE64-ENCODED PEM
# rather than a file path (internal/bootstrap/wire_infra_redis.go:237-239), so the
# bundle CAN be delivered — as a value, through External Secrets. That is what
# makes transit_encryption_mode = "required" plus an auth token an option for this
# tier rather than a chart change. See the tfvars.
################################################################################

################################################################################
# Cross-stack context (assert the derived strings without opening the tfvars)
################################################################################

output "vpc_name" {
  description = "tag:Name of the VPC the replication group was placed in, as derived or overridden. Should equal the vpc_name output of infra-base/vpc."
  value       = module.network.vpc_name
}

output "eks_cluster_name" {
  description = "EKS cluster whose node security group was looked up. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to tenant-manager."
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
  description = "ARN of the Secrets Manager secret holding the auth token: tenant-manager-{env}-valkey/auth-token in dedicated mode, shared-{env}-valkey/auth-token in shared mode."
  value       = module.valkey.secret_arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret holding the auth token. The token exists whether or not ElastiCache enforces it. It is NOT usable as-is by this chart: see the REDIS_USER note in helm_values."
  value       = module.valkey.secret_name
}

output "identifier" {
  description = "ElastiCache replication group id: tenant-manager-{environment}-valkey in dedicated mode, the resolved shared-{env}-valkey in shared mode."
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
  description = "Whether ElastiCache is ENFORCING the auth token stored in secret_name. False means the token exists but is not required. THIS ESTATE SETS TRUE — see the tfvars: tenant-manager reads REDIS_PASSWORD and REDIS_CA_CERT (base64 PEM, not a path), and leaves REDIS_USERNAME unset, which is exactly what the legacy password-only AUTH of ElastiCache expects. The looser default elsewhere in this repository exists for charts that cannot carry a password; this service can."
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
# tenant-manager's chart lives in the internal gitops repository, not here, so
# these key names come from its configuration struct
# (internal/bootstrap/config.go:88-94), which is the authority.
#
# TWO CONNECT PATHS, BRANCHED ON REDIS_USERNAME BEING NON-EMPTY
# (internal/bootstrap/wire_infra_redis.go:41). Non-empty takes a direct go-redis
# ACL client; empty takes the lib-commons path. ElastiCache auth tokens are the
# LEGACY password-only AUTH, which has NO USERNAME, so REDIS_USERNAME must stay
# UNSET here — setting it sends AUTH <user> <token> to a server that expects
# AUTH <token> and the connection is rejected. It is therefore not emitted.
#
# REDIS_CA_CERT IS BASE64-ENCODED PEM, NOT A FILE PATH
# (wire_infra_redis.go:237-239). A chart that mounts a CA file and points this at
# the path produces a TLS handshake failure that reads like a certificate problem.
# It is a value from External Secrets, not a volume.
#
# THE TLS POSTURE OF THIS TIER IS WEAKER THAN THE SERVICE SUPPORTS. The module
# defaults to transit_encryption_mode = "preferred", which ACCEPTS A PLAINTEXT
# CLIENT, and auth_token_enabled = false. tenant-manager reads REDIS_TLS,
# REDIS_PASSWORD and REDIS_CA_CERT, so it can speak to a "required" tier with an
# auth token — this is one of the few places where the known-gap posture is a
# tfvars decision rather than a chart limitation. See the tfvars.
################################################################################

output "helm_values" {
  description = "tenant-manager env vars this datastore fills in. REDIS_USERNAME is deliberately absent: ElastiCache auth is the legacy password-only AUTH with no username, and setting it switches the service onto a different connect path whose handshake the server rejects. REDIS_PASSWORD and REDIS_CA_CERT (base64 PEM, not a path) come from External Secrets."
  value = {
    REDIS_HOST = module.valkey.endpoint
    REDIS_PORT = tostring(module.valkey.port)
    REDIS_TLS  = var.transit_encryption_enabled ? "true" : "false"
  }
}
