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
# to remove — there was no single host to alias.
#
# The module is NOT under count here — this root wraps exactly one datastore —
# so a plain module.msk.x reference is safe.
#
# In shared mode this stack does not read the shared tier's state file. It
# resolves the cluster by NAME (data "aws_msk_cluster" on shared-{env}-msk) plus
# the Secrets Manager entry, exactly like every other shared consumer.
################################################################################

locals {
  ################################################################################
  # STREAMING_TLS_ENABLED reflects what the CLUSTER will accept.
  #
  # encryption_in_transit_client_broker = "TLS" means the brokers accept TLS
  # only, so the client must use it. "TLS_PLAINTEXT" accepts both and
  # "PLAINTEXT" accepts neither TLS nor SASL/SCRAM — SASL/SCRAM on MSK requires
  # TLS in transit, which is why enable_sasl_scram and this setting move
  # together.
  ################################################################################
  streaming_tls_enabled = var.encryption_in_transit_client_broker == "TLS"

  ################################################################################
  # The SASL block is emitted only when SASL/SCRAM is actually on, and
  # STREAMING_SASL_MECHANISM only when the operator has supplied a spelling —
  # see var.streaming_sasl_mechanism for why Terraform refuses to guess it.
  ################################################################################
  helm_sasl_values = var.enable_sasl_scram ? merge({
    STREAMING_SASL_USERNAME        = var.scram_username
    STREAMING_SASL_ALLOW_PLAINTEXT = "false"
    }, var.streaming_sasl_mechanism == "" ? {} : {
    STREAMING_SASL_MECHANISM = var.streaming_sasl_mechanism
  }) : {}

  helm_cloudevents_values = var.streaming_cloudevents_source == "" ? {} : {
    STREAMING_CLOUDEVENTS_SOURCE = var.streaming_cloudevents_source
  }
}

################################################################################
# Cross-stack context (assert the derived strings without opening the tfvars)
################################################################################

output "vpc_name" {
  description = "tag:Name of the VPC the brokers were placed in, as derived or overridden. Should equal the vpc_name output of infra-base/vpc."
  value       = module.network.vpc_name
}

output "eks_cluster_name" {
  description = "EKS cluster whose node security group was looked up. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to plugin-fees."
  value       = module.network.eks_cluster_name
}

output "ingress_security_group_ids" {
  description = "Security groups authorised on the brokers. Empty in shared mode — authorising plugin-fees on the shared cluster is products/shared-resources/msk's job."
  value       = module.network.ingress_security_group_ids
}

output "ingress_cidr_blocks" {
  description = "CIDR blocks authorised on the brokers. Holds the Type=private subnet CIDRs while allow_private_subnet_cidr_ingress is true. Empty in shared mode."
  value       = module.network.ingress_cidr_blocks
}

################################################################################
# Uniform datastore contract
################################################################################

output "mode" {
  description = "Provisioning mode this stack ran in: dedicated (created plugin-fees-{env}-msk) or shared (resolved shared-{env}-msk)."
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
  description = "Security group protecting the brokers. Null in shared mode — a product consuming the shared tier creates no security group and cannot authorise itself."
  value       = module.msk.security_group_id
}

output "secret_arn" {
  description = "ARN of the SASL/SCRAM secret: AmazonMSK_plugin-fees-{env}-msk in dedicated mode, AmazonMSK_shared-{env}-msk in shared mode. Null when enable_sasl_scram is false."
  value       = module.msk.secret_arn
}

output "secret_name" {
  description = "Name of the SASL/SCRAM secret. Carries the AWS-mandated AmazonMSK_ prefix rather than the usual {name}/password path. This is the value an External Secrets Operator ExternalSecret references to populate the chart's STREAMING_SASL_PASSWORD key."
  value       = module.msk.secret_name
}

output "identifier" {
  description = "MSK cluster name: plugin-fees-{environment}-msk in dedicated mode, the resolved shared-{env}-msk in shared mode."
  value       = module.msk.identifier
}

################################################################################
# Kafka specifics
################################################################################

output "bootstrap_brokers_sasl_scram" {
  description = "SASL/SCRAM bootstrap brokers (port 9096). Empty unless enable_sasl_scram is true."
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
  description = "ARN of the MSK cluster, for IAM policy resources."
  value       = module.msk.cluster_arn
}

output "cluster_uuid" {
  description = "UUID of the MSK cluster, for use in IAM policy resources that scope to topics or groups."
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

output "log_group_arn" {
  description = "ARN of the CloudWatch log group receiving broker logs. Null when cloudwatch_logs_enabled is false."
  value       = module.msk.log_group_arn
}

################################################################################
# Helm handoff
#
# Verified against chart plugin-fees-helm 7.3.0 (appVersion 3.4.0),
# templates/fees/configmap.yaml lines 119-126 and templates/fees/secrets.yaml
# lines 35-39. The chart defines EIGHT STREAMING_* ConfigMap keys and two Secret
# keys, and that is the complete set.
#
################################################################################
# THE SAME GAP AS midaz: STREAMING_BROKERS DOES NOT EXIST IN THIS CHART.
#
# This was checked independently rather than assumed from the midaz finding.
# grep for STREAMING across plugin-fees-helm 7.3.0 returns exactly thirteen
# hits — the eight ConfigMap keys, the two Secret keys and three values.yaml
# entries — and grep -i for "broker" and for "kafka" returns ZERO. The chart can
# turn streaming on and configure its TLS and its SASL, and has nowhere to put a
# broker address.
#
# So STREAMING_BROKERS below has to be injected through fees.extraEnvVars until
# the chart grows the variable. It is emitted under that name because that is the
# name the streaming-msk module README already uses, so the day the chart adds it
# the wiring is a rename and not a discovery exercise.
#
################################################################################
# A SECOND CHART TRAP, worth knowing before wiring TLS.
#
# templates/fees/deployment.yaml lists envFrom as secretRef FIRST and
# configMapRef SECOND. In Kubernetes the later source wins on a duplicate key,
# and STREAMING_TLS_CA_CERT is defined in BOTH — the ConfigMap always renders it
# (default: five literal spaces), so it overwrites whatever an operator puts in
# the Secret. If a CA bundle is ever needed here, it has to go in the ConfigMap
# copy or through extraEnvVars, not the Secret. Reported upstream; not something
# Terraform can work around.
#
# NOT emitted here, on purpose:
#   STREAMING_SASL_PASSWORD — read from secret_name by External Secrets, never
#     an output.
#   STREAMING_TLS_CA_CERT   — the public Amazon trust store already covers the
#     MSK broker certificates, so nothing needs distributing; and see the
#     precedence trap above.
#   STREAMING_SASL_MECHANISM — omitted unless var.streaming_sasl_mechanism is
#     set. MSK is SCRAM-SHA-512, but the spelling the client parser accepts is
#     not verifiable from the chart. CONFIRMAR against lib-streaming.
#   STREAMING_IMPORTANT_EMIT_TIMEOUT_MS — a client timeout, not an
#     infrastructure fact.
################################################################################

output "helm_values" {
  description = "plugin-fees chart env vars this cluster fills in, ready to merge into .Values.fees.configmap — EXCEPT STREAMING_BROKERS, which has no key in plugin-fees-helm 7.3.0 and must go through fees.extraEnvVars. STREAMING_ENABLED is emitted as \"true\" because a consumer reading this map has, by definition, provisioned or resolved a cluster; the chart default is \"false\"."
  value = merge({
    STREAMING_ENABLED     = "true"
    STREAMING_TLS_ENABLED = local.streaming_tls_enabled ? "true" : "false"

    # NOT A CHART KEY TODAY — see the header. Inject through fees.extraEnvVars.
    STREAMING_BROKERS = module.msk.endpoint
  }, local.helm_sasl_values, local.helm_cloudevents_values)
}
