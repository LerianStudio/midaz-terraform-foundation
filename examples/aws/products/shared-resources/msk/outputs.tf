################################################################################
# Outputs
#
# The seven uniform contract names (mode, endpoint, port, security_group_id,
# secret_arn, secret_name, identifier) are passed straight through from the
# module, so an operator script reads this stack the same way regardless of
# which datastore it wraps.
#
# `endpoint` is a comma separated bootstrap broker LIST, not a host: a Kafka
# client bootstraps from several brokers. That is also why MSK never had a CNAME
# to remove — there was no single host to alias — and why it was the template
# the other four datastores converged on when the private zone went away.
#
# There is no `msk_enabled` output any more. It existed when this tier was one
# root with five toggles; enablement is now "this directory was applied".
#
# The module is NOT under count here — this root wraps exactly one datastore —
# so a plain module.msk.x reference is safe.
#
# Products do NOT read this state with terraform_remote_state. They resolve the
# shared tier by NAME — data "aws_msk_cluster" on shared-{env}-msk plus the
# Secrets Manager entry.
################################################################################

################################################################################
# Cross-stack context (assert the derived strings without opening the tfvars)
################################################################################

output "vpc_name" {
  description = "tag:Name of the VPC the brokers were placed in, as derived or overridden. Should equal the vpc_name output of infra-base/vpc."
  value       = module.network.vpc_name
}

output "eks_cluster_name" {
  description = "EKS cluster whose node security group was looked up. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to this tier."
  value       = module.network.eks_cluster_name
}

output "ingress_security_group_ids" {
  description = "Security groups authorised on the brokers. Empty before infra-base/eks exists unless allowed_security_group_ids was passed explicitly."
  value       = module.network.ingress_security_group_ids
}

output "ingress_cidr_blocks" {
  description = "CIDR blocks authorised on the brokers. Holds the Type=private subnet CIDRs while allow_private_subnet_cidr_ingress is true."
  value       = module.network.ingress_cidr_blocks
}

################################################################################
# Uniform datastore contract
################################################################################

output "mode" {
  description = "Provisioning mode the module ran in. Always \"dedicated\" here: this stack CREATES the shared cluster. Products consume it with mode = \"shared\" — see the header of main.tf."
  value       = module.msk.mode
}

output "endpoint" {
  description = "Bootstrap broker list for the strongest enabled auth mode. Kafka has no single host, so this is a comma separated host:port list, not a hostname."
  value       = module.msk.endpoint
}

output "port" {
  description = "Client port for the strongest enabled auth mode: 9096 SASL/SCRAM, 9094 TLS, 9092 plaintext. Already embedded in the bootstrap list."
  value       = module.msk.port
}

output "security_group_id" {
  description = "Security group protecting the shared brokers. This stack owns its ingress; a product consuming with mode = \"shared\" gets null from its own module."
  value       = module.msk.security_group_id
}

output "secret_arn" {
  description = "ARN of AmazonMSK_shared-{environment}-msk. Null when enable_sasl_scram is false."
  value       = module.msk.secret_arn
}

output "secret_name" {
  description = "Name of the SASL/SCRAM secret. Carries the AWS-mandated AmazonMSK_ prefix rather than the usual {name}/password path, and is the exact name streaming-msk resolves in shared mode."
  value       = module.msk.secret_name
}

output "identifier" {
  description = "MSK cluster name, shared-{environment}-msk. This is the name a shared consumer resolves with data \"aws_msk_cluster\"."
  value       = module.msk.identifier
}

################################################################################
# Kafka specifics
################################################################################

output "bootstrap_brokers_sasl_scram" {
  description = "SASL/SCRAM bootstrap brokers (port 9096) of the shared cluster. Empty unless enable_sasl_scram is true."
  value       = module.msk.bootstrap_brokers_sasl_scram
}

output "bootstrap_brokers_tls" {
  description = "TLS bootstrap brokers (port 9094) of the shared cluster."
  value       = module.msk.bootstrap_brokers_tls
}

output "bootstrap_brokers" {
  description = "Plaintext bootstrap brokers (port 9092). Empty unless encryption_in_transit_client_broker allows PLAINTEXT."
  value       = module.msk.bootstrap_brokers
}

output "zookeeper_connect_string" {
  description = "ZooKeeper connection string. Empty on Kafka versions running in KRaft mode."
  value       = module.msk.zookeeper_connect_string
}

output "cluster_arn" {
  description = "ARN of the shared MSK cluster, for IAM policy resources."
  value       = module.msk.cluster_arn
}

output "cluster_uuid" {
  description = "UUID of the shared MSK cluster, for use in IAM policy resources that scope to topics or groups."
  value       = module.msk.cluster_uuid
}

output "configuration_arn" {
  description = "ARN of the aws_msk_configuration attached to the cluster."
  value       = module.msk.configuration_arn
}

output "kms_key_arn" {
  description = "CMK encrypting broker data at rest. Null when an external key was supplied."
  value       = module.msk.kms_key_arn
}

output "scram_kms_key_arn" {
  description = "CMK encrypting the SASL/SCRAM secret. AWS requires a customer managed key on any secret associated with an MSK cluster. Null when SASL/SCRAM is disabled."
  value       = module.msk.scram_kms_key_arn
}

output "log_group_arn" {
  description = "ARN of the CloudWatch log group receiving broker logs. Null when cloudwatch_logs_enabled is false."
  value       = module.msk.log_group_arn
}

################################################################################
# Helm handoff
#
# SCOPE WARNING, AND A REAL GAP. Unlike the other four datastores in this tier,
# there is currently NO chart variable that carries a Kafka broker address.
#
# The midaz chart (8.7.0, appVersion 3.8.0) defines exactly three streaming
# variables — STREAMING_ENABLED, STREAMING_SASL_PASSWORD and
# STREAMING_TLS_CA_CERT — and STREAMING_ENABLED is not even present in
# values.yaml; the "false" lives only in templates/ledger/configmap.yaml and
# templates/crm/configmap.yaml. STREAMING_BROKERS DOES NOT EXIST.
#
# So the bootstrap list below has to be injected through ledger.extraEnvVars /
# crm.extraEnvVars until the chart grows a variable for it. STREAMING_BROKERS is
# emitted here under the name the module README already uses, so that the day
# the chart adds it, the wiring is a rename and not a discovery exercise.
#
# NOT emitted here, on purpose:
#   STREAMING_SASL_PASSWORD — read from secret_name by External Secrets.
#   STREAMING_TLS_CA_CERT   — the public Amazon trust store covers the MSK
#     broker certificates; distributing a bundle is a chart concern.
#   STREAMING_ENABLED       — a product decision, not an infrastructure fact.
#     Emitted as "true" only because a consumer reading this map has, by
#     definition, provisioned the cluster.
################################################################################

output "helm_values" {
  description = "Chart env vars this cluster fills in. READ THE HEADER FIRST: STREAMING_BROKERS does not exist in the midaz chart today and must be injected through ledger.extraEnvVars / crm.extraEnvVars. The value itself — the bootstrap list for the strongest enabled auth mode — is correct and tier-level."
  value = {
    STREAMING_ENABLED = "true"
    STREAMING_BROKERS = module.msk.endpoint
  }
}
