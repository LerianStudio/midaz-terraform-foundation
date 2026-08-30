################################################################################
# Uniform datastore contract outputs.
# Names are identical across postgres-rds, mongodb-documentdb,
# valkey-elasticache, rabbitmq-amazonmq and streaming-msk so that product roots
# and lerian-infra can treat every datastore the same way.
#
# `endpoint` is the RAW AWS broker host in BOTH modes. There is no dns_name
# output and no private CNAME anywhere in this repository: AmazonMQ exposes no
# plaintext AMQP listener, so the client always speaks AMQPS, and the broker
# certificate is issued for *.mq.{region}.on.aws — an alias in front of it fails
# hostname verification. This module already behaved that way for its Helm
# handoff; the CNAME it used to publish alongside is simply gone.
#
# Every reference goes through one(...[*]...) rather than [0]. A conditional
# expression evaluates BOTH of its result branches, so a bare [0] on a
# count = 0 resource fails even in the branch that is not selected. It happens to
# work today only because local.create is known at plan time and Terraform
# short-circuits; that is an implementation detail, not a guarantee, and it does
# not survive a refactor that makes the condition unknown.
################################################################################

output "mode" {
  description = "Lerian sharing mode this module ran in: dedicated or shared. Not the AmazonMQ topology - see broker_deployment_mode."
  value       = var.mode
}

output "endpoint" {
  description = "Raw AWS broker host, with no scheme and no port — the RABBITMQ_HOST value for the Helm values. In shared mode this is the host of the broker resolved through data \"aws_mq_broker\" (see data.tf for the topology-suffix caveat)."
  value       = local.broker_host
}

output "port" {
  description = "AMQPS port of the broker (5671), parsed from the endpoint AmazonMQ reports in both modes. AmazonMQ exposes no plaintext AMQP listener, which is why RABBITMQ_URI must be \"amqps\"."
  value       = local.amqp_port
}

output "security_group_id" {
  description = "Security group protecting the broker. Null in shared mode - opening the shared broker is the responsibility of the shared-resources/rabbitmq ingress."
  value       = one(aws_security_group.mq[*].id)
}

output "secret_arn" {
  description = "ARN of the Secrets Manager secret holding the admin password."
  value = (
    local.create
    ? one(aws_secretsmanager_secret.mq_password[*].arn)
    : one(data.aws_secretsmanager_secret.shared[*].arn)
  )
}

output "secret_name" {
  description = "Name of the Secrets Manager secret holding the admin password."
  value = (
    local.create
    ? one(aws_secretsmanager_secret.mq_password[*].name)
    : one(data.aws_secretsmanager_secret.shared[*].name)
  )
}

output "identifier" {
  description = "AmazonMQ broker id (b-xxxxxxxx). In shared mode this is the id of the resolved shared broker, not null."
  value = (
    local.create
    ? one(aws_mq_broker.main[*].id)
    : one(data.aws_mq_broker.shared[*].id)
  )
}

################################################################################
# AmazonMQ specific
################################################################################

output "amqp_endpoint" {
  description = "Full AMQP URI including scheme and port, exactly as AmazonMQ reports it (amqps://host:5671), in both modes."
  value       = local.amqp_endpoint_raw
}

output "console_url" {
  description = "URL of the RabbitMQ management console. Reachability depends on enable_console_ingress, which opens console_port (443) on the security group — in shared mode that ingress belongs to products/shared-resources/rabbitmq."
  value       = try(local.broker_console_urls[0], null)
}

output "endpoints" {
  description = "Every endpoint AmazonMQ reports for the broker, in both modes. For a RabbitMQ cluster there is no stable primary, so ordering is not guaranteed."
  value       = local.broker_endpoints
}

output "broker_name" {
  description = "Broker name as it exists in AWS, including the -single / -cluster suffix. In shared mode this is local.shared_broker_name — the exact string the lookup used, so a caller can assert which broker was resolved."
  value       = local.create ? local.broker_name : local.shared_broker_name
}

output "broker_deployment_mode" {
  description = "AmazonMQ topology of the broker: SINGLE_INSTANCE or CLUSTER_MULTI_AZ. Read from the resolved broker in shared mode rather than echoed from var.broker_deployment_mode, which describes a broker this module did not create."
  value = (
    local.create
    ? var.broker_deployment_mode
    : one(data.aws_mq_broker.shared[*].deployment_mode)
  )
}

output "is_cluster_mode" {
  description = "Whether the broker is deployed in CLUSTER_MULTI_AZ topology. Derived from the resolved broker in shared mode."
  value = (
    local.create
    ? local.is_cluster_deployment
    : one(data.aws_mq_broker.shared[*].deployment_mode) == "CLUSTER_MULTI_AZ"
  )
}

output "arn" {
  description = "ARN of the AmazonMQ broker. Resolved from the shared broker in shared mode."
  value = (
    local.create
    ? one(aws_mq_broker.main[*].arn)
    : one(data.aws_mq_broker.shared[*].arn)
  )
}

output "admin_username" {
  description = "Administrator username. Echoed from var.mq_admin_user: the MQ data source reports broker users as an unordered set, so in shared mode this reflects what the CALLER declared, not a read of the shared broker."
  value       = var.mq_admin_user
  sensitive   = true
}

output "ingress_ports" {
  description = "Ports the security group actually opens to the resolved ingress sources: AMQPS (port), plus the management console (console_port) when enable_console_ingress is true."
  value       = local.ingress_ports
}
