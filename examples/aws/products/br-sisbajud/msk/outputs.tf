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

locals {
  ################################################################################
  # STREAMING_TLS_ENABLED reports the listener the bootstrap list points at.
  #
  # `endpoint` carries the bootstrap brokers of the STRONGEST enabled auth mode,
  # so the two have to agree:
  #
  #   enable_sasl_scram = true  -> port 9096, which MSK serves over TLS ONLY (the
  #                               streaming-msk module refuses SASL/SCRAM without
  #                               TLS in transit), so this is true.
  #   otherwise                 -> TLS when encryption_in_transit_client_broker
  #                               offers it (TLS or TLS_PLAINTEXT), false on
  #                               PLAINTEXT.
  ################################################################################
  streaming_tls_enabled = (
    var.enable_sasl_scram ||
    contains(["TLS", "TLS_PLAINTEXT"], var.encryption_in_transit_client_broker)
  )

  ################################################################################
  # The SASL half of the contract is emitted only when SASL/SCRAM is on.
  #
  # The chart's topics Job renders the optional STREAMING_SASL_* keys only when
  # they carry a value (templates/topics/job.yaml:39-42), so an empty string is
  # not equivalent to omitting the key: it would render an empty env var and make
  # rpk attempt a SASL handshake with no mechanism.
  ################################################################################
  streaming_sasl_values = var.enable_sasl_scram ? {
    # SCRAM-SHA-512 is the only mechanism MSK offers. The chart's own upgrade doc
    # shows SCRAM-SHA-256 as the example (docs/UPGRADE-1.1.md:122) — that value
    # does not authenticate against MSK.
    STREAMING_SASL_MECHANISM = "SCRAM-SHA-512"
    STREAMING_SASL_USERNAME  = var.scram_username
  } : {}
}

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
  description = "EKS cluster whose node security group was looked up. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to br-sisbajud."
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
  description = "ARN of the Secrets Manager secret holding the SASL/SCRAM credentials: AmazonMSK_br-sisbajud-{env}-msk in dedicated mode, AmazonMSK_shared-{env}-msk in shared mode. Null when enable_sasl_scram is false."
  value       = module.msk.secret_arn
}

output "secret_name" {
  description = "Name of the SASL/SCRAM secret. It carries the AWS-mandated AmazonMSK_ prefix rather than the {name}/password path every other Lerian datastore uses — AWS rejects any other name on a secret associated with an MSK cluster. This is the value an External Secrets Operator ExternalSecret references to populate STREAMING_SASL_PASSWORD."
  value       = module.msk.secret_name
}

output "identifier" {
  description = "MSK cluster name: br-sisbajud-{environment}-msk in dedicated mode, the resolved shared-{env}-msk in shared mode."
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

output "log_group_arn" {
  description = "ARN of the CloudWatch log group receiving broker logs. Null when cloudwatch_logs_enabled is false."
  value       = module.msk.log_group_arn
}

################################################################################
# Helm handoff
#
# THIS IS THE ONE LERIAN CHART WITH A REAL, COMPLETE STREAMING CONTRACT. Do not
# reason about it from products/shared-resources/msk, whose header documents the
# midaz gap: midaz defines only STREAMING_ENABLED, STREAMING_SASL_PASSWORD and
# STREAMING_TLS_CA_CERT, and has NO STREAMING_BROKERS at all, so the bootstrap
# list has to be smuggled in through extraEnvVars.
#
# br-sisbajud has the opposite problem: none. Verified against chart 1.1.0
# (appVersion 1.0.0-beta.109):
#
#   values-template.yaml:23-25   STREAMING_ENABLED "true", STREAMING_BROKERS ""
#                                (commented REQUIRED when STREAMING_ENABLED=true)
#                                and STREAMING_CLOUDEVENTS_SOURCE "br-sisbajud",
#                                all under brSisbajud.configmap
#   templates/topics/job.yaml:27-32
#                                the PreSync topics Job declares the full set it
#                                resolves from extraEnvVars then configmap:
#                                  STREAMING_BROKERS         required
#                                  STREAMING_TLS_ENABLED     required, default "false"
#                                  STREAMING_SASL_MECHANISM  optional
#                                  STREAMING_SASL_USERNAME   optional
#                                  STREAMING_SASL_PASSWORD   optional
#                                  STREAMING_TLS_CA_CERT     optional
#   README.md:28                 "a producer with STREAMING_ENABLED=true and empty
#                                STREAMING_BROKERS fails closed at boot by design"
#
# STREAMING_SASL_MECHANISM = "SCRAM-SHA-512" is not a preference. SASL/SCRAM on
# MSK is SCRAM-SHA-512 only; SCRAM-SHA-256 is not offered, and the chart's own
# example text uses SHA-256 (docs/UPGRADE-1.1.md:122) which would fail to
# authenticate against MSK. It is emitted here so nobody copies that example.
#
# STREAMING_TLS_ENABLED tracks the actual listener: MSK serves SASL/SCRAM on 9096
# over TLS ONLY, and the module already refuses SASL/SCRAM without TLS in
# transit. With enable_sasl_scram = false and PLAINTEXT in transit it correctly
# reports "false".
#
# NOT emitted here, on purpose:
#   STREAMING_SASL_PASSWORD — read from secret_name by External Secrets, never an
#     output. Note the secret is AmazonMSK_{name}, not {name}/password.
#   STREAMING_TLS_CA_CERT   — MSK broker certificates chain to the public Amazon
#     trust store, so no bundle needs distributing. Emitting an empty value would
#     be worse than omitting it: the topics Job renders the key only when set.
#   STREAMING_CLOUDEVENTS_SOURCE — an application identity ("br-sisbajud"), not an
#     infrastructure fact. The chart already defaults it correctly.
#
# TOPICS ARE NOT CREATED BY TERRAFORM. The chart's PreSync Job owns the six
# topics and their partition/replication/retention settings. See README.md — in
# particular, topics.replicationFactor defaults to 1 and must be raised to 3 on a
# multi-broker cluster, which every cluster this root creates is.
################################################################################

output "helm_values" {
  description = "br-sisbajud chart env vars this cluster fills in, ready to merge into brSisbajud.configmap. The same keys are what the PreSync topics Job resolves, so no duplicate wiring is needed. STREAMING_SASL_PASSWORD comes from secret_name through External Secrets and is deliberately absent."
  value = merge(
    {
      # STREAMING_ENABLED is the chart's own default ("true", values-template.yaml:23)
      # and is echoed rather than decided here: a consumer reading this map has,
      # by definition, provisioned or resolved a cluster.
      STREAMING_ENABLED     = "true"
      STREAMING_BROKERS     = module.msk.endpoint
      STREAMING_TLS_ENABLED = local.streaming_tls_enabled ? "true" : "false"
    },
    local.streaming_sasl_values,
  )
}
