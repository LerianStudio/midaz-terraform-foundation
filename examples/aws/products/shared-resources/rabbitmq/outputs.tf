################################################################################
# Outputs
#
# The seven uniform contract names (mode, endpoint, port, security_group_id,
# secret_arn, secret_name, identifier) are passed straight through from the
# module, so an operator script reads this stack the same way regardless of
# which datastore it wraps.
#
# There is no dns_name output and no private zone: AmazonMQ presents a
# certificate for *.mq.{region}.on.aws and has no plaintext AMQP listener, so a
# CNAME in front of the broker breaks TLS hostname verification for every
# client. `endpoint` is the raw AWS host.
#
# There is no `rabbitmq_enabled` output any more. It existed when this tier was
# one root with five toggles; enablement is now "this directory was applied".
#
# The module is NOT under count here — this root wraps exactly one datastore —
# so a plain module.rabbitmq.x reference is safe.
#
# Products do NOT read this state with terraform_remote_state. They resolve the
# shared tier by NAME — data "aws_mq_broker" on the name below, suffix included,
# plus the Secrets Manager entry.
################################################################################

################################################################################
# Cross-stack context (assert the derived strings without opening the tfvars)
################################################################################

output "vpc_name" {
  description = "tag:Name of the VPC the broker was placed in, as derived or overridden. Should equal the vpc_name output of infra-base/vpc."
  value       = module.network.vpc_name
}

output "eks_cluster_name" {
  description = "EKS cluster whose node security group was looked up. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to this tier."
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
  description = "Lerian sharing mode the module ran in. Always \"dedicated\" here: this stack CREATES the shared broker. NOT the AmazonMQ topology — see broker_deployment_mode."
  value       = module.rabbitmq.mode
}

output "endpoint" {
  description = "Raw AWS broker host, with no scheme and no port — the RABBITMQ_HOST value. Raw because AmazonMQ has no plaintext AMQP listener, so the client always speaks AMQPS and the broker certificate covers *.mq.{region}.on.aws only."
  value       = module.rabbitmq.endpoint
}

output "port" {
  description = "AMQPS port of the shared broker (5671). AmazonMQ exposes no plaintext AMQP listener, which is why every chart must set its RabbitMQ scheme to \"amqps\"."
  value       = module.rabbitmq.port
}

output "security_group_id" {
  description = "Security group protecting the shared broker. This stack owns its ingress; a product consuming with mode = \"shared\" gets null from its own module."
  value       = module.rabbitmq.security_group_id
}

output "secret_arn" {
  description = "ARN of shared-{environment}-rabbitmq/password."
  value       = module.rabbitmq.secret_arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret holding the admin password. It carries NO topology suffix, which is why a shared consumer resolves the secret without knowing whether the broker is -single or -cluster. This is the value an External Secrets Operator ExternalSecret references."
  value       = module.rabbitmq.secret_name
}

output "identifier" {
  description = "AmazonMQ broker id (b-xxxxxxxx)."
  value       = module.rabbitmq.identifier
}

################################################################################
# AmazonMQ specifics
################################################################################

output "broker_name" {
  description = "Broker name as created in AWS, INCLUDING the -single / -cluster suffix. THIS IS THE STRING A SHARED CONSUMER MUST PUT IN shared_broker_name — data \"aws_mq_broker\" matches it exactly and the provider has no list/filter data source for MQ, so it cannot be discovered. Copy it verbatim: `terraform output -raw broker_name`."
  value       = module.rabbitmq.broker_name
}

output "broker_deployment_mode" {
  description = "AmazonMQ topology of the shared broker: SINGLE_INSTANCE or CLUSTER_MULTI_AZ. The axis that decides the suffix in broker_name."
  value       = module.rabbitmq.broker_deployment_mode
}

output "is_cluster_mode" {
  description = "Whether the shared broker is deployed in CLUSTER_MULTI_AZ topology."
  value       = module.rabbitmq.is_cluster_mode
}

output "amqp_endpoint" {
  description = "Full AMQP URI exactly as AmazonMQ reports it, amqps://host:5671. The one to use when an AMQPS client wants a single connection string rather than a split host/port/scheme."
  value       = module.rabbitmq.amqp_endpoint
}

output "console_url" {
  description = "URL of the RabbitMQ management console of the shared broker. Reachability depends on enable_console_ingress, which opens console_port (443) on the security group."
  value       = module.rabbitmq.console_url
}

output "endpoints" {
  description = "Every endpoint AmazonMQ reports for the broker. For a RabbitMQ cluster there is no stable primary, so ordering is not guaranteed."
  value       = module.rabbitmq.endpoints
}

output "arn" {
  description = "ARN of the AmazonMQ broker."
  value       = module.rabbitmq.arn
}

output "ingress_ports" {
  description = "Ports the security group actually opens to the resolved ingress sources: AMQPS, plus the management console when enable_console_ingress is true."
  value       = module.rabbitmq.ingress_ports
}

output "admin_username" {
  description = "Administrator username configured on the shared broker. Read from the stack variable rather than from the module output, which is marked sensitive and would redact anything it is merged into."
  value       = var.mq_admin_user
}

################################################################################
# Helm handoff
#
# SCOPE WARNING. These are the env var names of the midaz chart, verified
# against chart 8.7.0 (appVersion 3.8.0), templates/ledger/configmap.yaml. This
# tier is consumed by ANY product, and products/midaz/README.md is explicit that
# other Lerian charts must not be assumed to use the same names — the inverted
# RABBITMQ_PORT_* pair below is a midaz-chart convention, not a Lerian-wide one.
# The FACTS — host, AMQPS port, console port, admin user — are tier-level and
# identical for every consumer.
#
# THE TWO PORT VARIABLES ARE NAMED BACKWARDS IN THE CHART. Not a typo below —
# the ledger init container reads them that way:
#
#   RABBITMQ_PORT_HOST  ->  the AMQP(S) port      (5672 upstream, 5671 here)
#   RABBITMQ_PORT_AMQP  ->  the management HTTP port (15672 upstream, 443 here)
#
# RABBITMQ_URI and RABBITMQ_PROTOCOL are SCHEMES, not URIs:
#   RABBITMQ_URI      "amqps" — AmazonMQ publishes no plaintext AMQP listener, so
#                     the chart default "amqp" cannot connect at all.
#   RABBITMQ_PROTOCOL "https" — the management API is HTTPS on 443.
#
# NOT emitted here, on purpose:
#   RABBITMQ_DEFAULT_PASS / RABBITMQ_CONSUMER_PASS — read from secret_name by
#     External Secrets. The chart marks both `required` and fails the install
#     when they are empty.
#   RABBITMQ_VHOST — AmazonMQ creates the default "/" vhost. Which vhost a
#     product uses is a chart decision, and on a SHARED broker giving each
#     product its own vhost is the sane isolation boundary — created on the
#     broker, outside Terraform.
#   RABBITMQ_CONSUMER_USER — the module creates ONE broker user; per-product
#     users are created on the broker itself.
################################################################################

output "helm_values" {
  description = "Chart env vars this broker fills in (midaz naming — see the header), ready to merge into ledger.configmap. Pair it with rabbitmq.enabled = false so the bundled subchart is not deployed alongside AmazonMQ. Note the chart has NO rabbitmq.external key — enabled = false is the whole switch. NOTE: this map is FLAT and midaz-named, and it is operator reference only — the tier serves several products and cannot know any one chart's components. Programmatic consumers must not read it: `lerian-infra --action helm-values` builds each product's values from this root's FACTS (endpoint, port, username, secret_name) via pkg/infra/chartmap.go, keyed by that product's chart components."
  value = {
    RABBITMQ_URI      = "amqps"
    RABBITMQ_PROTOCOL = "https"
    RABBITMQ_HOST     = module.rabbitmq.endpoint

    # Named backwards on purpose — see the header.
    RABBITMQ_PORT_HOST = tostring(module.rabbitmq.port)
    RABBITMQ_PORT_AMQP = tostring(var.console_port)


    # No *_USER key here either: this is the MASTER identity, and the chart's
    # bootstrap Jobs create the scoped user the workload authenticates as.
    # See products/midaz/<engine>/outputs.tf for the full reasoning.
  }
}
