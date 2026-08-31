################################################################################
# Outputs
#
# The seven uniform contract names (mode, endpoint, port, security_group_id,
# secret_arn, secret_name, identifier) are passed straight through from the
# module, unchanged, so every products/*/* root answers `terraform output` the
# same way regardless of which datastore it wraps.
#
# TWO of the seven mean something different here, and both differences are real
# rather than a wrapper quirk:
#
#   endpoint     a comma separated bootstrap broker LIST, not a host. A Kafka
#                client bootstraps from several brokers, which is also why MSK
#                never had a private CNAME to remove: there was no single host
#                to alias in the first place.
#   secret_name  carries the AWS-mandated AmazonMSK_ prefix instead of the usual
#                {name}/password path.
#
# There is no dns_name output and no private zone.
#
# The module is NOT under count here — this root wraps exactly one datastore —
# so a plain module.msk.x reference is safe.
################################################################################

################################################################################
# Cross-stack context (assert the derived strings without opening the tfvars)
#
# Re-exported from module.network, which owns the derivation. Note the "lerian"
# prefix on the VPC and the cluster: those are FOUNDATION names and keep it.
################################################################################

output "vpc_name" {
  description = "tag:Name of the VPC the brokers were placed in, as derived or overridden. Should equal the vpc_name output of infra-base/vpc. Null-ish in shared mode, where no lookup runs."
  value       = module.network.vpc_name
}

output "eks_cluster_name" {
  description = "EKS cluster whose node security group was looked up. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to br-sfn."
  value       = module.network.eks_cluster_name
}

output "ingress_security_group_ids" {
  description = "Security groups authorised on the brokers. Empty before infra-base/eks exists unless allowed_security_group_ids was passed explicitly, and empty in shared mode."
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
  description = "Provisioning mode this stack ran in: dedicated or shared."
  value       = module.msk.mode
}

output "endpoint" {
  description = "Bootstrap broker list for the strongest enabled auth mode — the STREAMING_BROKERS value. Kafka has no single host, so this is a comma separated host:port list, not a hostname. In shared mode it is the bootstrap list of shared-{env}-msk, resolved by name."
  value       = module.msk.endpoint
}

output "port" {
  description = "Client port for the strongest enabled auth mode: 9096 SASL/SCRAM, 9094 TLS, 9092 plaintext. Already embedded in every entry of the bootstrap list, so the chart never needs it separately."
  value       = module.msk.port
}

output "security_group_id" {
  description = "Security group protecting the brokers. Null in shared mode — ingress on the shared cluster is owned by products/shared-resources/msk."
  value       = module.msk.security_group_id
}

output "secret_arn" {
  description = "ARN of the Secrets Manager secret holding the SASL/SCRAM credentials: AmazonMSK_br-sfn-{env}-msk in dedicated mode, AmazonMSK_shared-{env}-msk in shared mode. Null when enable_sasl_scram is false."
  value       = module.msk.secret_arn
}

output "secret_name" {
  description = "Name of the SASL/SCRAM secret. It carries the AWS-mandated AmazonMSK_ prefix rather than the {name}/password path every other Lerian datastore uses — AWS rejects any other name on a secret associated with an MSK cluster. This is the value an External Secrets Operator ExternalSecret references to populate STREAMING_SASL_PASSWORD."
  value       = module.msk.secret_name
}

output "identifier" {
  description = "MSK cluster name: br-sfn-{environment}-msk in dedicated mode, the resolved shared-{env}-msk in shared mode."
  value       = module.msk.identifier
}

################################################################################
# Kafka specifics
################################################################################

output "bootstrap_brokers_sasl_scram" {
  description = "SASL/SCRAM bootstrap brokers (port 9096). Empty unless enable_sasl_scram is true. This is what `endpoint` carries in the default configuration."
  value       = module.msk.bootstrap_brokers_sasl_scram
}

output "bootstrap_brokers_tls" {
  description = "TLS bootstrap brokers (port 9094)."
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
  description = "ARN of the MSK cluster. Resolved from the shared cluster in shared mode."
  value       = module.msk.cluster_arn
}

output "cluster_uuid" {
  description = "UUID of the MSK cluster, for IAM policy resources that scope to topics or consumer groups."
  value       = module.msk.cluster_uuid
}

output "configuration_arn" {
  description = "ARN of the aws_msk_configuration attached to the cluster. Null in shared mode."
  value       = module.msk.configuration_arn
}

output "kms_key_arn" {
  description = "CMK encrypting broker data at rest. Null in shared mode or when an external key was supplied."
  value       = module.msk.kms_key_arn
}

output "scram_kms_key_arn" {
  description = "CMK encrypting the SASL/SCRAM secret. AWS requires a customer managed key on any secret associated with an MSK cluster. Null in shared mode or when SASL/SCRAM is disabled."
  value       = module.msk.scram_kms_key_arn
}

output "scram_username" {
  description = "SASL/SCRAM username configured on the cluster. Published as a first-class output BECAUSE helm_values is empty here: the br-sfn chart names no streaming variable, so an operator wiring the rails by hand needs this value alongside endpoint, port and secret_name. Read from the stack variable, which is what the module receives."
  value       = var.scram_username
}

output "log_group_arn" {
  description = "ARN of the CloudWatch log group receiving broker logs. Null when cloudwatch_logs_enabled is false."
  value       = module.msk.log_group_arn
}

################################################################################
# Helm handoff — DELIBERATELY EMPTY
#
# Verified against br-sfn chart 1.1.0 (appVersion 1.0.0-beta.1).
#
# THE BR-SFN CHART NAMES NO STREAMING VARIABLE. Not one. A grep for STREAMING,
# KAFKA, REDPANDA or BROKER over the entire chart — values.yaml,
# values-template.yaml, values.schema.json and every template — returns only
# prose:
#
#   Chart.yaml:43-45          "Postgres, Valkey/Redis, RabbitMQ, RedPanda and
#                              IBM MQ are EXTERNAL, pre-provisioned services"
#   README.md:40-42           the four SPI components "ride one Postgres, one
#                              Redis and one RedPanda"
#   README.md:78-79           "RedPanda topics for spb/spi are an environment
#                              concern (the compose redpanda-topics one-shot is
#                              dev-only)"
#   templates/common/NOTES.txt:30  the same infra contract, restated
#
# So the chart confirms that a Kafka API is consumed and confirms nothing about
# HOW it is configured. <component>.configmap is emitted verbatim with no
# allowlist, which means the variable names live in the br-sfn application
# repository, not here.
#
#   # CONFIRMAR no chart: the streaming env var names read by the spb and spi
#   # rails — the broker list, the TLS switch and the SASL mechanism/username
#   # keys. Two plausible shapes exist in the fleet and they are NOT compatible:
#   #
#   #   br-sisbajud (lib-streaming, complete)  STREAMING_BROKERS,
#   #                                          STREAMING_TLS_ENABLED,
#   #                                          STREAMING_SASL_MECHANISM,
#   #                                          STREAMING_SASL_USERNAME,
#   #                                          STREAMING_SASL_PASSWORD
#   #   midaz (lib-streaming, incomplete)      STREAMING_ENABLED only — it has NO
#   #                                          broker variable at all
#   #
#   # br-sfn may use either, both or neither. Ask the br-sfn service owners; do
#   # not infer it from a sibling chart.
#
# EMITTING A GUESS HERE WOULD BE ACTIVELY HARMFUL. Because the chart passes
# component configmaps through untouched, a wrong key name lands in the
# ConfigMap without any error and the rail falls back to whatever default it
# compiles in — a broker list pointing nowhere, discovered in production.
#
# WHAT TO USE IN THE MEANTIME. The values are all here; only the key names are
# missing:
#
#   endpoint                      the bootstrap broker list (host:port,...)
#   port                          9096 with SASL/SCRAM on
#   scram_username (var)          the SASL username
#   secret_name                   AmazonMSK_br-sfn-{env}-msk -> the SASL password,
#                                 via External Secrets. NOT the usual
#                                 {name}/password path — AWS mandates the prefix.
#
# and the mechanism is SCRAM-SHA-512, which is the only one MSK offers.
#
# TOPICS. br-sfn provisions none — no PreSync rpk Job, nothing. The chart calls
# it an environment concern. Something must create them before the rails
# publish; auto_create_topics_enable stays false so that gap fails loudly instead
# of silently creating topics with broker defaults.
################################################################################

output "helm_values" {
  description = "EMPTY ON PURPOSE. The br-sfn chart names no streaming variable at all — a grep for STREAMING/KAFKA/REDPANDA over the whole chart returns only prose about external infra. The values are available as endpoint, port, scram_username and secret_name; the KEY NAMES have to come from the br-sfn service owners. See the header: a guessed key is silently ignored by this chart, which is worse than no key."
  value       = {}
}
