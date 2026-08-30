################################################################################
# Uniform datastore contract
#
# These seven outputs carry the same names in every _modules datastore so a
# product root stack and lerian-infra can treat postgres, valkey, docdb,
# rabbitmq and msk identically.
#
# `endpoint` is the RAW AWS primary endpoint in BOTH modes. There is no dns_name
# output and no private CNAME anywhere in this repository: the ElastiCache
# in-transit certificate covers *.{cluster}.{region}.cache.amazonaws.com only,
# so a CNAME in front of the primary endpoint fails TLS hostname verification —
# which matters here more than anywhere else, because this module runs with
# transit_encryption_enabled = true.
#
# Every reference goes through one(...[*]...) rather than [0]. A conditional
# expression evaluates both of its result branches, so a bare [0] on a
# count = 0 resource fails even in the branch that is not selected.
################################################################################

output "mode" {
  description = "Provisioning mode this module ran in: dedicated or shared."
  value       = var.mode
}

output "endpoint" {
  description = "Raw AWS primary endpoint address of the replication group — the host half of REDIS_HOST. In shared mode this is the primary endpoint of shared-{environment}-valkey, resolved by name through data \"aws_elasticache_replication_group\"."
  value = (
    local.create
    ? one(module.valkey[*].replication_group_primary_endpoint_address)
    : one(data.aws_elasticache_replication_group.shared[*].primary_endpoint_address)
  )
}

output "port" {
  description = "Valkey port. Read from the resolved group in shared mode rather than echoed from var.port, which describes the group this module would have created."
  value = (
    local.create
    ? var.port
    : one(data.aws_elasticache_replication_group.shared[*].port)
  )
}

output "security_group_id" {
  description = "ID of the security group attached to the replication group. Null in shared mode - ingress is owned by products/shared-resources/valkey."
  value       = one(module.valkey[*].security_group_id)
}

output "secret_arn" {
  description = "ARN of the Secrets Manager secret holding the auth token."
  value = (
    local.create
    ? one(aws_secretsmanager_secret.auth[*].arn)
    : one(data.aws_secretsmanager_secret.shared[*].arn)
  )
}

output "secret_name" {
  description = "Name of the Secrets Manager secret holding the auth token."
  value = (
    local.create
    ? one(aws_secretsmanager_secret.auth[*].name)
    : one(data.aws_secretsmanager_secret.shared[*].name)
  )
}

output "identifier" {
  description = "ElastiCache replication group ID. In shared mode this is the resolved shared-{environment}-valkey, not null: the lookup is by that exact name, so echoing it back is what lets a caller assert which group was resolved."
  value = (
    local.create
    ? one(module.valkey[*].replication_group_id)
    : one(data.aws_elasticache_replication_group.shared[*].replication_group_id)
  )
}

################################################################################
# Valkey specifics
################################################################################

output "reader_endpoint" {
  description = "Reader endpoint address of the replication group. Resolved from the shared group in shared mode."
  value = (
    local.create
    ? one(module.valkey[*].replication_group_reader_endpoint_address)
    : one(data.aws_elasticache_replication_group.shared[*].reader_endpoint_address)
  )
}

output "engine_version_actual" {
  description = "Running version of the cache engine. Null in shared mode — the ElastiCache data source does not report it."
  value       = one(module.valkey[*].replication_group_engine_version_actual)
}

output "auth_token_enabled" {
  description = "Whether ElastiCache is enforcing the auth token stored in secret_name. Read from the resolved group in shared mode."
  value = (
    local.create
    ? var.auth_token_enabled
    : one(data.aws_elasticache_replication_group.shared[*].auth_token_enabled)
  )
}

output "transit_encryption_enabled" {
  description = "Whether in-transit encryption is enabled on the replication group. Echoed from the variable: the ElastiCache data source does not report it, so in shared mode this reflects what the CALLER declared, not what the shared group runs."
  value       = var.transit_encryption_enabled
}

output "subnet_group_name" {
  description = "Name of the cache subnet group. Null in shared mode."
  value       = one(module.valkey[*].subnet_group_name)
}
