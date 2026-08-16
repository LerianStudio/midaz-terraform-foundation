################################################################################
# Uniform datastore contract outputs.
# Names are identical across postgres-rds, mongodb-documentdb,
# valkey-elasticache, rabbitmq-amazonmq and streaming-msk so that product roots
# and deploy.sh can treat every datastore the same way.
#
# `endpoint` is the RAW AWS writer endpoint in BOTH modes. There is no dns_name
# output and no private CNAME anywhere in this repository: the DocumentDB server
# certificate covers *.docdb.amazonaws.com only, so an alias in front of it
# fails hostname validation on every driver that verifies it.
#
# Every reference goes through one(...[*]...) rather than [0]. A conditional
# expression evaluates BOTH of its result branches, so a bare [0] on a
# count = 0 resource fails even in the branch that is not selected. It happens to
# work today only because local.create is known at plan time and Terraform
# short-circuits; that is an implementation detail, not a guarantee, and it does
# not survive a refactor that makes the condition unknown.
################################################################################

output "mode" {
  description = "Mode this module ran in: dedicated or shared."
  value       = var.mode
}

output "endpoint" {
  description = "Raw AWS writer endpoint of the DocumentDB cluster — the MONGO_*_HOST value for the Helm values. In shared mode this is the writer endpoint of shared-{environment}-docdb, resolved by identifier (see data.tf)."
  value = (
    local.create
    ? one(aws_docdb_cluster.main[*].endpoint)
    : one(data.aws_rds_cluster.shared[*].endpoint)
  )
}

output "port" {
  description = "Port the cluster listens on. Read from the resolved cluster in shared mode."
  value = (
    local.create
    ? one(aws_docdb_cluster.main[*].port)
    : one(data.aws_rds_cluster.shared[*].port)
  )
}

output "security_group_id" {
  description = "Security group protecting the cluster. Null in shared mode - opening the shared cluster is the responsibility of the shared-resources/documentdb ingress."
  value       = one(aws_security_group.docdb[*].id)
}

output "secret_arn" {
  description = "ARN of the Secrets Manager secret holding the master password."
  value = (
    local.create
    ? one(aws_secretsmanager_secret.docdb_password[*].arn)
    : one(data.aws_secretsmanager_secret.shared[*].arn)
  )
}

output "secret_name" {
  description = "Name of the Secrets Manager secret holding the master password."
  value = (
    local.create
    ? one(aws_secretsmanager_secret.docdb_password[*].name)
    : one(data.aws_secretsmanager_secret.shared[*].name)
  )
}

output "identifier" {
  description = "DocumentDB cluster identifier. In shared mode this is the resolved shared-{environment}-docdb, not null: the lookup is by that exact name, so echoing it back is what lets a caller assert which cluster was resolved."
  value = (
    local.create
    ? one(aws_docdb_cluster.main[*].cluster_identifier)
    : one(data.aws_rds_cluster.shared[*].cluster_identifier)
  )
}

################################################################################
# DocumentDB specific
################################################################################

output "reader_endpoint" {
  description = "Raw AWS reader endpoint of the DocumentDB cluster, for read-only connections. Resolved from the shared cluster in shared mode — data \"aws_rds_cluster\" reports reader_endpoint for a docdb cluster (verified in a real account)."
  value = (
    local.create
    ? one(aws_docdb_cluster.main[*].reader_endpoint)
    : one(data.aws_rds_cluster.shared[*].reader_endpoint)
  )
}

output "arn" {
  description = "ARN of the DocumentDB cluster. Resolved from the shared cluster in shared mode."
  value = (
    local.create
    ? one(aws_docdb_cluster.main[*].arn)
    : one(data.aws_rds_cluster.shared[*].arn)
  )
}

output "master_username" {
  description = "Master username configured on the cluster. Read from the resolved cluster in shared mode, where var.master_username describes a cluster this module did not create."
  value = (
    local.create
    ? var.master_username
    : one(data.aws_rds_cluster.shared[*].master_username)
  )
  sensitive = true
}

output "kms_key_arn" {
  description = "ARN of the CMK encrypting the cluster storage. Null in shared mode."
  value       = one(module.docdb_kms_key[*].key_arn)
}
