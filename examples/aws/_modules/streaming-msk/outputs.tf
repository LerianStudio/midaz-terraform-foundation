################################################################################
# Uniform datastore contract outputs
#
# Same names as every other Lerian datastore module, so a product root stack and
# deploy.sh can treat MSK like postgres, valkey or rabbitmq.
################################################################################

output "mode" {
  description = "The mode this module ran in: dedicated or shared."
  value       = var.mode
}

output "endpoint" {
  description = "Bootstrap broker list for the strongest enabled authentication mode. Kafka has no single endpoint, so this is a comma separated host:port list, not a host."
  value       = local.brokers_for_clients
}

output "port" {
  description = "Client port for the strongest enabled authentication mode: 9096 SASL/SCRAM, 9094 TLS, 9092 plaintext. Already embedded in the bootstrap broker list."
  value       = local.client_port
}

output "security_group_id" {
  description = "Security group protecting the brokers. Null in shared mode, where ingress belongs to the shared-resources/msk stack."
  value       = one(aws_security_group.msk[*].id)
}

output "secret_arn" {
  description = "ARN of the Secrets Manager secret holding the SASL/SCRAM credentials. Null when SASL/SCRAM is disabled."
  value       = local.dedicated ? one(aws_secretsmanager_secret.scram[*].arn) : one(data.aws_secretsmanager_secret.shared[*].arn)
}

output "secret_name" {
  description = "Name of the SASL/SCRAM secret. Carries the AWS mandated AmazonMSK_ prefix instead of the usual {name}/password path."
  value       = local.dedicated ? one(aws_secretsmanager_secret.scram[*].name) : one(data.aws_secretsmanager_secret.shared[*].name)
}

output "identifier" {
  description = "MSK cluster name. Null in shared mode is not applicable here — the shared cluster name is what the lookup resolves, so it is returned."
  value       = local.dedicated ? one(module.msk[*].cluster_name) : one(data.aws_msk_cluster.shared[*].cluster_name)
}

################################################################################
# Kafka specific outputs
################################################################################

output "bootstrap_brokers" {
  description = "Plaintext bootstrap brokers (port 9092). Empty unless encryption_in_transit_client_broker allows PLAINTEXT."
  value       = local.bootstrap_brokers
}

output "bootstrap_brokers_tls" {
  description = "TLS bootstrap brokers (port 9094)."
  value       = local.bootstrap_brokers_tls
}

output "bootstrap_brokers_sasl_scram" {
  description = "SASL/SCRAM bootstrap brokers (port 9096). Empty unless enable_sasl_scram is true."
  value       = local.bootstrap_brokers_sasl_scram
}

output "zookeeper_connect_string" {
  description = "ZooKeeper connection string. Empty on Kafka versions running in KRaft mode."
  value       = local.zookeeper_connect_string
}

output "cluster_arn" {
  description = "ARN of the MSK cluster."
  value       = local.dedicated ? one(module.msk[*].arn) : one(data.aws_msk_cluster.shared[*].arn)
}

output "cluster_uuid" {
  description = "UUID of the MSK cluster, for use in IAM policy resources."
  value       = local.dedicated ? one(module.msk[*].cluster_uuid) : one(data.aws_msk_cluster.shared[*].cluster_uuid)
}

output "configuration_arn" {
  description = "ARN of the aws_msk_configuration attached to the cluster. Null when create_configuration is false or in shared mode."
  value       = one(module.msk[*].configuration_arn)
}

output "kms_key_arn" {
  description = "CMK encrypting broker data at rest. Null in shared mode or when an external key was supplied."
  value       = one(module.msk_kms_key[*].key_arn)
}

output "scram_kms_key_arn" {
  description = "CMK encrypting the SASL/SCRAM secret. Null in shared mode or when SASL/SCRAM is disabled."
  value       = one(module.msk_secret_kms_key[*].key_arn)
}

output "log_group_arn" {
  description = "ARN of the CloudWatch log group receiving broker logs. Null when cloudwatch_logs_enabled is false."
  value       = one(module.msk[*].log_group_arn)
}
