################################################################################
# Outputs
#
# The seven uniform contract names (mode, endpoint, port, security_group_id,
# secret_arn, secret_name, identifier) are passed straight through from the
# module, so every Lerian datastore root can be consumed the same way regardless
# of which datastore it wraps.
#
# There is no dns_name output and no private zone: every AWS datastore presents
# a certificate for its own service domain, so a CNAME in front of it breaks TLS
# hostname verification. `endpoint` is the raw AWS host in both modes.
#
# The module is NOT under count here — this root stack wraps exactly one
# datastore — so a plain module.rabbitmq.x reference is safe. The one(...)
# gymnastics live inside the module, where the count actually is.
################################################################################

################################################################################
# Cross-stack context (assert the derived strings without opening the tfvars)
#
# Re-exported from module.network, which owns the derivation. Note the "lerian"
# prefix on the VPC and the cluster: those are FOUNDATION names and keep it,
# while the shared datastore tier carries "shared".
################################################################################

output "vpc_name" {
  description = "tag:Name of the VPC the broker was placed in, as derived or overridden. Should equal the vpc_name output of infra-base/vpc."
  value       = module.network.vpc_name
}

output "eks_cluster_name" {
  description = "EKS cluster whose node security group was looked up. Should equal the cluster_name output of infra-base/eks. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to notifications."
  value       = module.network.eks_cluster_name
}

output "ingress_security_group_ids" {
  description = "Security groups authorised on the broker. Empty before infra-base/eks exists unless allowed_security_group_ids was passed explicitly."
  value       = module.network.ingress_security_group_ids
}

output "ingress_cidr_blocks" {
  description = "CIDR blocks authorised on the broker. Holds the Type=private subnet CIDRs while allow_private_subnet_cidr_ingress is true."
  value       = module.network.ingress_cidr_blocks
}

################################################################################
# Uniform datastore contract
################################################################################

output "mode" {
  description = "Provisioning mode this stack ran in: dedicated or shared."
  value       = module.rabbitmq.mode
}

output "endpoint" {
  description = "Raw AWS broker host, with no scheme and no port. It is the raw host because AmazonMQ has no plaintext AMQP listener, so the client always speaks AMQPS, and the broker certificate covers *.mq.{region}.on.aws only. In shared mode this is the host of the broker resolved by shared_broker_name."
  value       = module.rabbitmq.endpoint
}

output "port" {
  description = "AMQPS port of the broker (5671). AmazonMQ exposes no plaintext AMQP listener, which is why every client URI must use the \"amqps\" scheme."
  value       = module.rabbitmq.port
}

output "security_group_id" {
  description = "Security group protecting the broker. Null in shared mode — ingress on the shared broker is owned by products/shared-resources/rabbitmq."
  value       = module.rabbitmq.security_group_id
}

output "secret_arn" {
  description = "ARN of the Secrets Manager secret holding the admin password: notifications-{env}-rabbitmq/password in dedicated mode, shared-{env}-rabbitmq/password in shared mode."
  value       = module.rabbitmq.secret_arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret holding the admin password. This is the value an External Secrets Operator ExternalSecret references."
  value       = module.rabbitmq.secret_name
}

output "identifier" {
  description = "AmazonMQ broker id (b-xxxxxxxx). In shared mode this is the id of the resolved shared broker."
  value       = module.rabbitmq.identifier
}

################################################################################
# AmazonMQ specifics
################################################################################

output "amqp_endpoint" {
  description = "Full AMQP URI exactly as AmazonMQ reports it, amqps://host:5671, in both modes. The one to use when an AMQPS client wants a single connection string rather than a split host/port/scheme — and the credential-free half of any URL that has to carry credentials."
  value       = module.rabbitmq.amqp_endpoint
}

output "console_url" {
  description = "URL of the RabbitMQ management console, in both modes. Reachability depends on enable_console_ingress, which opens console_port (443) on the security group."
  value       = module.rabbitmq.console_url
}

output "endpoints" {
  description = "Every endpoint AmazonMQ reports for the broker, in both modes. For a RabbitMQ cluster there is no stable primary, so ordering is not guaranteed."
  value       = module.rabbitmq.endpoints
}

output "broker_name" {
  description = "Broker name as it exists in AWS, including the -single / -cluster suffix. In shared mode this is the exact string the lookup used, so it can be asserted against the shared tier."
  value       = module.rabbitmq.broker_name
}

output "broker_deployment_mode" {
  description = "AmazonMQ topology of the broker: SINGLE_INSTANCE or CLUSTER_MULTI_AZ. Read from the resolved broker in shared mode, so it also verifies that shared_broker_name pointed at the topology you expected."
  value       = module.rabbitmq.broker_deployment_mode
}

output "is_cluster_mode" {
  description = "Whether the broker is deployed in CLUSTER_MULTI_AZ topology."
  value       = module.rabbitmq.is_cluster_mode
}

output "arn" {
  description = "ARN of the AmazonMQ broker. Resolved from the shared broker in shared mode."
  value       = module.rabbitmq.arn
}

output "ingress_ports" {
  description = "Ports the security group actually opens to the resolved ingress sources: AMQPS, plus the management console when enable_console_ingress is true."
  value       = module.rabbitmq.ingress_ports
}

output "admin_username" {
  description = "Administrator username configured on the broker. Read from the stack variable rather than from the module output, which is marked sensitive and would redact anything it is merged into."
  value       = var.mq_admin_user
}

################################################################################
# Helm handoff
#
# Verified against chart 1.0.0-beta.4 (appVersion 0.1.0), values.yaml `config`
# and `secrets`, plus values-template.yaml. One shared ConfigMap and one shared
# Secret for api and all three workers.
#
# THE TWO PORT VARIABLES ARE NAMED THE OTHER WAY ROUND FROM MIDAZ. Read this
# twice before copying anything from products/midaz/rabbitmq:
#
#                        notifications chart      midaz chart
#   RABBITMQ_PORT_AMQP   the AMQP(S) port         the management HTTP port
#   RABBITMQ_PORT_HOST   the management HTTP port the AMQP(S) port
#
# The evidence is the chart's own defaults (values.yaml config block):
# RABBITMQ_PORT_AMQP: "5672" and RABBITMQ_PORT_HOST: "15672" — 5672 is AMQP and
# 15672 is the management API upstream, so on this chart each name means what it
# says. values-template.yaml reinforces it by listing RABBITMQ_PORT_AMQP as the
# one port an operator normally overrides. midaz's inversion is a midaz-chart
# convention and is NOT Lerian-wide.
#
# The AmazonMQ values are 5671 (AMQPS, there is no plaintext listener) and 443
# (management over HTTPS), not the 5672/15672 the chart defaults to.
#
# NOT emitted here, on purpose:
#   RABBITMQ_URL — the chart's full AMQP URL, and it embeds the credentials.
#     Terraform must not build it: it would land in state and in
#     `terraform output` in cleartext. Assemble it in the secret store from
#     secret_name plus the endpoint published here. Shape:
#     amqps://USER:URLENCODED_PW@HOST:5671/  (see also the amqp_endpoint output,
#     which is the same URI without credentials).
#   RABBITMQ_DEFAULT_PASS — read from secret_name by External Secrets.
#   RABBITMQ_HEALTH_CHECK_URL — the chart keeps it in .Values.secrets, which
#     means it is expected to carry credentials for the management API. The
#     host half is https://<endpoint> and the port is omitted (443 is implicit),
#     but the credential half and the exact path are the chart's to decide.
#     # CONFIRMAR no chart: the full expected shape of RABBITMQ_HEALTH_CHECK_URL
#     # (path and whether credentials are inline). Not emitted until confirmed.
#   RABBITMQ_VHOST — AmazonMQ creates the default "/" vhost and the chart default
#     is already "/", so there is nothing for Terraform to correct. Which vhost
#     the service should use is a chart decision.
#   RABBITMQ_EXCHANGE — application topology ("events"), not infrastructure.
#     Terraform creates no exchanges; the broker is empty on first boot.
################################################################################

output "helm_values" {
  description = "notifications chart env vars this broker fills in, ready to merge into .Values.config (the shared ConfigMap). The chart bundles no RabbitMQ subchart, so there is nothing to disable alongside AmazonMQ."
  value = {
    RABBITMQ_HOST = module.rabbitmq.endpoint

    # NOT swapped. On this chart _AMQP is the AMQP port and _HOST is the
    # management port — see the header for why, and for how midaz differs.
    RABBITMQ_PORT_AMQP = tostring(module.rabbitmq.port)
    RABBITMQ_PORT_HOST = tostring(var.console_port)
  }
}

output "helm_secret_values" {
  description = "The same handoff, for the keys the notifications chart routes through .Values.secrets instead of .Values.config. RABBITMQ_DEFAULT_USER is a username, not a credential, but the chart reads it from the Secret so it has to be written there — next to RABBITMQ_DEFAULT_PASS, which comes from secret_name."
  value = {
    RABBITMQ_DEFAULT_USER = var.mq_admin_user
  }
}
