################################################################################
# Uniform datastore contract
#
# These seven outputs carry the same names in every _modules datastore so a
# product root stack and deploy.sh can treat postgres, valkey, docdb, rabbitmq
# and msk identically.
#
# `endpoint` is the RAW AWS hostname in BOTH modes. There is no dns_name output
# and no private CNAME anywhere in this repository: the RDS server certificate
# covers *.{region}.rds.amazonaws.com only, so a CNAME in front of the instance
# fails TLS hostname verification on any client that checks it. The stability
# argument for a CNAME does not apply either — Helm values are generated from
# `terraform output` on every deploy, so there is no hardcoded host to protect.
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
  description = "Raw AWS hostname of the PostgreSQL instance — the DB_HOST value for the Helm values. In shared mode this is the hostname of shared-{environment}-postgres, resolved by name through data \"aws_db_instance\"."
  value = (
    local.create
    ? one(module.db[*].db_instance_address)
    : one(data.aws_db_instance.shared[*].address)
  )
}

output "port" {
  description = "PostgreSQL port. Read from the resolved instance in shared mode rather than echoed from var.port, which describes the instance this module would have created."
  value = (
    local.create
    ? var.port
    : one(data.aws_db_instance.shared[*].db_instance_port)
  )
}

output "security_group_id" {
  description = "ID of the security group attached to the instance. Null in shared mode - ingress is owned by products/shared-resources/postgres."
  value       = one(aws_security_group.this[*].id)
}

output "secret_arn" {
  description = "ARN of the Secrets Manager secret holding the master credentials."
  value = (
    local.create
    ? one(aws_secretsmanager_secret.this[*].arn)
    : one(data.aws_secretsmanager_secret.shared[*].arn)
  )
}

output "secret_name" {
  description = "Name of the Secrets Manager secret holding the master credentials."
  value = (
    local.create
    ? one(aws_secretsmanager_secret.this[*].name)
    : one(data.aws_secretsmanager_secret.shared[*].name)
  )
}

output "identifier" {
  description = "RDS DB instance identifier. In shared mode this is the resolved shared-{environment}-postgres, not null: the lookup is by that exact name, so echoing it back is what lets a caller assert which instance was resolved."
  value = (
    local.create
    ? one(module.db[*].db_instance_identifier)
    : one(data.aws_db_instance.shared[*].db_instance_identifier)
  )
}

################################################################################
# PostgreSQL specifics
################################################################################

output "database_name" {
  description = "Name of the initial database on the instance. Read from the resolved instance in shared mode."
  value = (
    local.create
    ? var.database_name
    : one(data.aws_db_instance.shared[*].db_name)
  )
}

output "username" {
  description = "Master username. Read from the resolved instance in shared mode, where var.username describes an instance this module did not create."
  value = (
    local.create
    ? var.username
    : one(data.aws_db_instance.shared[*].master_username)
  )
}

output "replica_endpoint" {
  description = "Raw AWS hostname of the read replica. Null when no replica is created, and null in shared mode — the shared read replica, if any, is published by products/shared-resources/postgres."
  value       = one(module.db_replica[*].db_instance_address)
}

output "replica_identifier" {
  description = "RDS DB instance identifier of the read replica. Null when no replica is created."
  value       = one(module.db_replica[*].db_instance_identifier)
}

output "subnet_group_name" {
  description = "Name of the DB subnet group. Null in shared mode."
  value       = one(aws_db_subnet_group.this[*].name)
}
