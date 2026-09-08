################################################################################
# Outputs
#
# The seven uniform contract names (mode, endpoint, port, security_group_id,
# secret_arn, secret_name, identifier) are passed straight through from the module,
# so every products/*/* root answers `terraform output` the same way.
#
# Two of the seven mean something different for Kafka, and both differences are
# real rather than a wrapper quirk:
#
#   endpoint     a comma separated bootstrap broker LIST, not a host.
#   secret_name  carries the AWS-mandated AmazonMSK_ prefix instead of the usual
#                {name}/password path.
#
# In the default shared mode every one of these resolves against shared-{env}-msk.
################################################################################

output "vpc_name" {
  description = "tag:Name of the VPC the brokers were placed in. Null-ish in shared mode, where no lookup runs."
  value       = module.network.vpc_name
}

output "eks_cluster_name" {
  description = "EKS cluster whose node security group was looked up. Note the \"lerian\" prefix: the cluster belongs to infra-base."
  value       = module.network.eks_cluster_name
}

output "ingress_security_group_ids" {
  description = "Security groups authorised on the brokers. Empty in shared mode — ingress there is owned by products/shared-resources/msk."
  value       = module.network.ingress_security_group_ids
}

output "ingress_cidr_blocks" {
  description = "CIDR blocks authorised on the brokers. Empty in shared mode."
  value       = module.network.ingress_cidr_blocks
}

################################################################################
# Uniform datastore contract
################################################################################

output "mode" {
  description = "Provisioning mode this stack ran in. SHOULD BE \"shared\": the hub can only consume what a producer wrote to the same cluster, and a dedicated broker here yields a healthy pod that consumes nothing."
  value       = module.msk.mode
}

output "endpoint" {
  description = "Bootstrap broker list for the strongest enabled auth mode — the STREAMING_HUB_KAFKA_BROKERS value. Kafka has no single host, so this is a comma separated host:port list."
  value       = module.msk.endpoint
}

output "port" {
  description = "Client port for the strongest enabled auth mode: 9096 SASL/SCRAM, 9094 TLS, 9092 plaintext. Already embedded in every entry of the bootstrap list."
  value       = module.msk.port
}

output "security_group_id" {
  description = "Security group protecting the brokers. Null in shared mode."
  value       = module.msk.security_group_id
}

output "secret_arn" {
  description = "ARN of the SASL/SCRAM secret. Null when enable_sasl_scram is false."
  value       = module.msk.secret_arn
}

output "secret_name" {
  description = "Name of the SASL/SCRAM secret, carrying the AWS-mandated AmazonMSK_ prefix. This is what an ExternalSecret references to populate STREAMING_HUB_KAFKA_SCRAM_PASSWORD."
  value       = module.msk.secret_name
}

output "identifier" {
  description = "MSK cluster name: shared-{env}-msk in shared mode."
  value       = module.msk.identifier
}

################################################################################
# Kafka specifics
################################################################################

output "bootstrap_brokers_sasl_scram" {
  description = "SASL/SCRAM bootstrap brokers (port 9096). This is what `endpoint` carries in the default configuration."
  value       = module.msk.bootstrap_brokers_sasl_scram
}

output "bootstrap_brokers_tls" {
  description = "TLS bootstrap brokers (port 9094)."
  value       = module.msk.bootstrap_brokers_tls
}

output "cluster_arn" {
  description = "ARN of the MSK cluster. Resolved from the shared cluster in shared mode."
  value       = module.msk.cluster_arn
}

output "cluster_uuid" {
  description = "UUID of the cluster, for IAM policies that scope to topics or consumer groups. Not used on this estate: the hub authenticates with SASL/SCRAM, not IAM, and its ACLs are created over the Kafka wire protocol."
  value       = module.msk.cluster_uuid
}

output "scram_kms_key_arn" {
  description = "CMK encrypting the SASL/SCRAM secret. FEED THIS INTO products/lerian-platform/eso AS kms_key_arns: AWS refuses an AWS-managed key on an MSK-associated secret, so without kms:Decrypt on this key External Secrets cannot project the password and the ExternalSecret sits in SecretSyncedError while every other secret syncs fine. Null in shared mode — take it from the shared tier's own output instead."
  value       = module.msk.scram_kms_key_arn
}

output "scram_username" {
  description = "SASL/SCRAM username configured on the cluster. Feeds STREAMING_HUB_KAFKA_SCRAM_USERNAME. Note that the module creates ONE cluster-wide user; the per-service principal the hub's ACL contract describes (streaminghub_{env}) is created against the cluster by tenant-manager over the Kafka protocol, outside Terraform."
  value       = var.scram_username
}

output "consumer_groups" {
  description = "Consumer groups the hub joins, derived from the service's own constants. Both need LITERAL READ + DESCRIBE in the Kafka ACL. They are suffixed with STREAMING_HUB_ENV, which is the APPLICATION's environment name and need not equal var.environment — on this estate it is \"production\" while var.environment is \"prd\"."
  value = {
    ingest = "streaming-hub.{STREAMING_HUB_ENV}"
    dlq    = "streaming-hub-dlq.{STREAMING_HUB_ENV}"
  }
}

output "topic_subscription_patterns" {
  description = "How the hub selects topics. IT SUBSCRIBES BY REGEX, so there is no fixed list to create here and no list Terraform could create: the set is whatever ce-source values the producers use. Ingest never matches .dlq or .commands. The Kafka ACL grant is PREFIXED READ + DESCRIBE on \"lerian.streaming.\"."
  value = {
    prefix = "lerian.streaming."
    ingest = "^lerian\\.streaming\\.<app>$"
    dlq    = "^lerian\\.streaming\\.<app>\\.dlq$"
  }
}

################################################################################
# Helm handoff — POPULATED, unlike the br-sfn root this was derived from
#
# The donor left helm_values empty because the br-sfn chart names no streaming
# variable and a guessed key would be silently ignored. That reasoning does not
# apply here for the opposite reason: streaming-hub HAS NO CHART AT ALL, so there
# is no chart to guess against — and its configuration loader
# (internal/bootstrap/config_load.go:33-38) names every variable exactly. These
# keys come from the application, which is the authority the chart will have to
# match when somebody writes it.
#
# THE PREFIX IS STREAMING_HUB_KAFKA_*, NOT STREAMING_KAFKA_*. The hub is a
# CONSUMER with its own configuration surface; the STREAMING_* names belong to
# lib-streaming's producer side and the hub does not read them. Wiring
# STREAMING_BROKERS here reaches nothing and the hub falls back to its default.
#
# SCRAM_USERNAME and SCRAM_PASSWORD are omitted deliberately: they are required
# TOGETHER whenever the mechanism is set, and the hub fails closed if only one
# arrives. Both come from the vault through External Secrets, not from here.
#
# The mechanism is scram-sha-512 because that is the only one MSK offers.
################################################################################

output "helm_values" {
  description = "Chart env vars this cluster fills in. Verified against streaming-hub's configuration loader, not against a chart — the service has none. Note the STREAMING_HUB_ prefix: the unprefixed STREAMING_* names are lib-streaming's producer surface and the hub does not read them. The SCRAM username and password are omitted on purpose; they are required together and both arrive from the vault via External Secrets."
  value = merge(
    {
      STREAMING_HUB_KAFKA_BROKERS = module.msk.endpoint

      # DERIVED, NOT HARDCODED. The module hands out the broker list of the
      # strongest enabled mode: SCRAM (9096, TLS) when SCRAM is on, else the TLS
      # list (9094) when transit encryption allows TLS, else the plaintext list
      # (9092). Announcing TLS over a plaintext bootstrap list makes the hub fail
      # the handshake against the broker, and the error names the broker rather
      # than this configuration. The condition mirrors that selection exactly.
      STREAMING_HUB_KAFKA_TLS_ENABLED = (
        var.enable_sasl_scram || contains(["TLS", "TLS_PLAINTEXT"], var.encryption_in_transit_client_broker)
        ? "true"
        : "false"
      )
    },
    # OMITTED, NOT EMPTIED, when SCRAM is off. The hub reads an empty mechanism as
    # "no SASL" and then fails authentication against a broker that requires it —
    # an error about the broker, not about the configuration.
    var.enable_sasl_scram ? { STREAMING_HUB_KAFKA_SCRAM_MECHANISM = "SCRAM-SHA-512" } : {},
  )
}
