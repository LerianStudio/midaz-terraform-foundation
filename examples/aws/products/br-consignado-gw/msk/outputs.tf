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
  description = "Provisioning mode this stack ran in. SHOULD BE \"shared\": the gateway produces the consignado fact stream that streaming-hub consumes, and a dedicated broker here means the hub never sees a single fact — with no error on either side."
  value       = module.msk.mode
}

output "endpoint" {
  description = "Bootstrap broker list for the strongest enabled auth mode — the STREAMING_BROKERS value. Kafka has no single host, so this is a comma separated host:port list."
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
  description = "Name of the SASL/SCRAM secret, carrying the AWS-mandated AmazonMSK_ prefix. This is what an ExternalSecret references to populate the SASL password file."
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
  description = "UUID of the cluster, for IAM policies that scope to topics or consumer groups. Not used on this estate: the gateway authenticates with SASL/SCRAM, not IAM."
  value       = module.msk.cluster_uuid
}

output "scram_kms_key_arn" {
  description = "CMK encrypting the SASL/SCRAM secret. FEED THIS INTO products/lerian-platform/eso AS kms_key_arns: AWS refuses an AWS-managed key on an MSK-associated secret, so without kms:Decrypt on this key External Secrets cannot project the password and the ExternalSecret sits in SecretSyncedError while every other secret syncs fine. Null in shared mode — take it from the shared tier's own output instead."
  value       = module.msk.scram_kms_key_arn
}

output "scram_username" {
  description = "SASL/SCRAM username configured on the cluster. Note that the module creates ONE cluster-wide user; per-service principals and ACLs are created against the cluster by tenant-manager over the Kafka wire protocol, outside Terraform."
  value       = var.scram_username
}

output "topics" {
  description = "Topics this service depends on, derived from lib-streaming's naming contract (prefix \"lerian.streaming.\", DLQ suffix \".dlq\", commands suffix \".commands\") and from the gateway's own source pin. NOTHING CREATES THEM — auto_create_topics_enable is false, and topic provisioning is an rpk Job in the helmfile phase. A missing produce topic is a fact stream that goes nowhere; a missing consume topic is a command plane that never delivers."
  value = {
    produces = "lerian.streaming.consignado-gw"
    dlq      = "lerian.streaming.consignado-gw.dlq"
    consumes = "lerian.streaming.lender.commands"
  }
}

output "consumer_group" {
  description = "Consumer group the gateway joins to read the lender command plane. Needs LITERAL READ + DESCRIBE in the Kafka ACL."
  value       = "br-consignado-gw.lender-commands"
}

################################################################################
# Helm handoff — POPULATED, unlike the br-sfn root this was derived from
#
# The donor left helm_values empty because the br-sfn chart names no streaming
# variable and a guessed key would be silently ignored.
#
# These keys come from the SERVICE's own configuration surface
# (internal/bootstrap/config.go:740-749), which names every variable exactly. A
# published chart does exist (br-consignado-gw-helm 1.0.1, ghcr helm-internal) but
# its values.yaml was NOT read while authoring this root — so treat the names below
# as the contract the chart has to satisfy, and reconcile them against the real
# values.yaml in the helmfile phase rather than assuming either side.
#
# THE CREDENTIALS ARE FILE PATHS, NOT VALUES, AND THAT CHANGES THE DEPLOYMENT.
# STREAMING_KAFKA_SASL_USERNAME_FILE and _PASSWORD_FILE are read from disk at boot.
# A chart that projects the SASL credential as an environment variable — which is
# what every other service on this estate does — produces a gateway that cannot
# authenticate to Kafka. It needs a MOUNTED VOLUME from the projected secret. Same
# for STREAMING_KAFKA_TLS_CA_FILE.
#
# The paths themselves are a chart decision, so they are not emitted here: emitting
# a path Terraform cannot guarantee exists would be worse than emitting nothing.
#
# A managed deployment REFUSES TO BOOT unless TLS is on, plaintext is off, the
# mechanism is a SCRAM variant and BOTH credential files are set.
################################################################################

output "helm_values" {
  description = "Chart env vars this cluster fills in. Verified against the gateway's CONFIGURATION SURFACE, not against the published chart (br-consignado-gw-helm 1.0.1, not read here) — reconcile in the helmfile phase. WARNING: the SASL credentials are FILE PATHS (STREAMING_KAFKA_SASL_USERNAME_FILE / _PASSWORD_FILE), so the projected secret must be MOUNTED AS A VOLUME, not injected as env vars. The paths are a chart decision and are deliberately not guessed here."
  value = merge(
    {
      STREAMING_ENABLED               = "true"
      STREAMING_BROKERS               = module.msk.endpoint
      STREAMING_KAFKA_TLS_ENABLED     = "true"
      STREAMING_KAFKA_ALLOW_PLAINTEXT = "false"
      STREAMING_CLOUDEVENTS_SOURCE    = "consignado-gw"
    },
    # OMITTED, NOT EMPTIED, when SCRAM is off. A key present with an empty value is
    # not the same as an absent key: it lands in the ConfigMap, the chart cannot
    # tell it apart from a deliberate setting, and the failure surfaces as a broker
    # auth error rather than as a configuration one.
    var.enable_sasl_scram ? { STREAMING_KAFKA_SASL_MECHANISM = "scram-sha-512" } : {},
  )
}
