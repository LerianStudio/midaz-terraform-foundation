output "broker_id" {
  description = "The ID of the broker."
  value       = aws_mq_broker.main.id
}

output "broker_arn" {
  description = "The ARN of the broker."
  value       = aws_mq_broker.main.arn
}

output "broker_endpoints" {
  description = "A list of broker endpoints."
  value       = aws_mq_broker.main.instances[*].endpoints
}

output "broker_console_url" {
  description = "The URL of the broker's web console."
  value       = aws_mq_broker.main.instances[*].console_url
}

output "mq_security_group_id" {
  description = "The ID of the security group for the MQ broker."
  value       = aws_security_group.mq.id
}

output "mq_password_secret_arn" {
  description = "The ARN of the secret containing the MQ admin password."
  value       = aws_secretsmanager_secret.mq_password.arn
}

output "broker_first_endpoint" {
  description = "The first endpoint from aws_mq_broker.main.instances[0].endpoints[0]. Note: For RabbitMQ clusters, there is no stable primary - ordering is not guaranteed. Use broker_endpoints for the full list."
  value       = try(aws_mq_broker.main.instances[0].endpoints[0], null)
}

output "is_cluster_mode" {
  description = "Whether the broker is deployed in cluster mode (CLUSTER_MULTI_AZ)."
  value       = var.deployment_mode == "CLUSTER_MULTI_AZ"
}