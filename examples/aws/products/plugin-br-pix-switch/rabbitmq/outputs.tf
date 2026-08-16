################################################################################
# Outputs
#
# The seven uniform contract names (mode, endpoint, port, security_group_id,
# secret_arn, secret_name, identifier) are passed straight through from the
# module, unchanged, so every products/*/* root answers `terraform output` the
# same way regardless of which datastore it wraps.
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
  description = "EKS cluster whose node security group was looked up. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to plugin-br-pix-switch."
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
  description = "Lerian sharing mode this stack ran in: dedicated or shared. NOT the AmazonMQ topology — see broker_deployment_mode."
  value       = module.rabbitmq.mode
}

output "endpoint" {
  description = "Raw AWS broker host, with no scheme and no port — what helm_values writes into RABBITMQ_HOST. It is the raw host because AmazonMQ has no plaintext AMQP listener, so the client always speaks AMQPS, and the broker certificate covers *.mq.{region}.on.aws only. In shared mode this is the host of the broker resolved by shared_broker_name."
  value       = module.rabbitmq.endpoint
}

output "port" {
  description = "AMQPS port of the broker (5671). AmazonMQ exposes no plaintext AMQP listener, which is why RABBITMQ_URI must be \"amqps\"."
  value       = module.rabbitmq.port
}

output "security_group_id" {
  description = "Security group protecting the broker. Null in shared mode — ingress on the shared broker is owned by products/shared-resources/rabbitmq."
  value       = module.rabbitmq.security_group_id
}

output "secret_arn" {
  description = "ARN of the Secrets Manager secret holding the admin password: plugin-br-pix-switch-{env}-rabbitmq/password in dedicated mode, shared-{env}-rabbitmq/password in shared mode."
  value       = module.rabbitmq.secret_arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret holding the admin password; it carries no topology suffix. This is the value an External Secrets Operator ExternalSecret references to populate RABBITMQ_DEFAULT_PASS and RABBITMQ_CONSUMER_PASS."
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
  description = "Full AMQP URI exactly as AmazonMQ reports it, amqps://host:5671, in both modes. The one to use when an AMQPS client wants a single connection string rather than the split host/port/scheme the chart uses."
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
# Helm handoff — DELIBERATELY EMPTY
#
# The chart reads the broker through ONE key, on ONE component, and that key is a
# full connection URL living in a Secret. Verified against chart 2.0.0-beta.1+:
#
#   values-template.yaml:102-104
#       dictHubVsync.secrets.RABBITMQ_URI ->
#       "amqps://pixswitch:<password>@rabbitmq-host:5671/", with the chart's own
#       comment: "TLS-only: amqps:// on 5671. lib-commons v5.7.0 validates the
#       broker cert against the system trust store (a private CA needs an
#       app-code change)."
#   values.yaml:1463-1494
#       "Used only by dict-hub-vsync for RABBITMQ_URI"; the embedded groundhog2k
#       subchart is disabled because it "would present a self-signed cert that
#       lib-commons rejects", and the comment names the target directly:
#       "For external RabbitMQ / AmazonMQ set enabled: false and configure
#        dictHubVsync.secrets.RABBITMQ_URI"
#   templates/dict-hub-vsync/secrets.yaml
#       the secrets map is emitted verbatim; no host key, no port key, no scheme
#       key, no user key
#
# TERRAFORM CANNOT FILL A SECRET, so helm_values is empty and rabbitmq_uri_template
# below carries the shape.
#
# THIS IS THE BEST-ALIGNED PAIRING IN THE PRODUCT. The chart's example already
# uses amqps on 5671, which is exactly what AmazonMQ serves and the only thing it
# serves — there is no plaintext AMQP listener. And its stated reason for
# rejecting the in-cluster broker (a self-signed certificate that lib-commons
# will not accept) is precisely what AmazonMQ solves: the broker presents a
# publicly-trusted certificate for *.mq.{region}.on.aws. That is also why
# `endpoint` must be used raw — an alias in front of it fails the same hostname
# verification.
#
# THE PASSWORD MUST BE URL-SAFE — AND NOW IS, BY CONSTRUCTION. It is being
# interpolated into a URL. The rabbitmq-amazonmq module USED TO generate it with
# override_special = "!#$%^&*()-_+{}<>?", which includes ? # and %. It now draws
# 32 characters from alphanumerics plus "-_.~", the RFC 3986 §2.3 unreserved
# set, so no percent-encoding is needed anywhere in the URI — see README.md,
# "The generated password is URL-safe — FIXED UPSTREAM".
#
# NOT emitted here, on purpose:
#   the password — read from secret_name by External Secrets.
#   any management/console key — the chart names none. products/midaz/rabbitmq
#     emits RABBITMQ_PORT_AMQP for the management API because the midaz ledger
#     health-checks against it; nothing here does.
#   the vhost — the trailing "/" in the chart's example is the default vhost
#     AmazonMQ creates. Which vhost the worker should use is an application
#     decision.
################################################################################

locals {
  # The broker user is created by the module; the chart's example username is
  # "pixswitch", which is a chart-side placeholder rather than a requirement —
  # the URL just has to carry whatever mq_admin_user is.
  rabbitmq_uri_template = "amqps://${var.mq_admin_user}:<password>@${module.rabbitmq.endpoint}:${module.rabbitmq.port}/"
}

output "helm_values" {
  description = "EMPTY ON PURPOSE. The chart's only AMQP key is dictHubVsync.secrets.RABBITMQ_URI — a full amqps:// connection URL containing the password — and this repository never emits a password. There is no non-secret host/port surface either. Use rabbitmq_uri_template. The chart ships rabbitmq.enabled = false already, so there is no subchart to disable."
  value       = {}
}

output "rabbitmq_uri_template" {
  description = "The dictHubVsync.secrets.RABBITMQ_URI template, with the password left as the literal placeholder <password>. Substitute the value behind secret_name and percent-encode it if it is not URL-safe. amqps and 5671 are not choices: AmazonMQ publishes no plaintext AMQP listener. The host is the raw broker endpoint because the certificate covers *.mq.{region}.on.aws only — which is exactly the publicly-trusted certificate the chart says lib-commons requires."
  value       = local.rabbitmq_uri_template
}
