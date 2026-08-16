################################################################################
# Outputs
#
# The seven uniform contract names (mode, endpoint, port, security_group_id,
# secret_arn, secret_name, identifier) are passed straight through from the
# datastore module, so every product root looks the same regardless of which
# datastore it wraps.
#
# There is no dns_name output and no private zone: every AWS datastore presents
# a certificate for its own service domain, so a CNAME in front of it breaks TLS
# hostname verification. `endpoint` is the raw AWS host in both modes.
#
# The module is NOT under count here — this root stack wraps exactly one
# broker — so a plain module.rabbitmq.x reference is safe. The
# one(...) gymnastics live inside the module, where the count actually is.
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
  description = "EKS cluster whose node security group was looked up. Should equal the cluster_name output of infra-base/eks. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to fetcher."
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
  description = "AMQPS port of the broker (5671). AmazonMQ exposes no plaintext AMQP listener."
  value       = module.rabbitmq.port
}

output "security_group_id" {
  description = "Security group protecting the broker. Null in shared mode — ingress on the shared one is owned by products/shared-resources/rabbitmq."
  value       = module.rabbitmq.security_group_id
}

output "secret_arn" {
  description = "ARN of the Secrets Manager secret holding the admin password: fetcher-{env}-rabbitmq/password in dedicated mode, shared-{env}-rabbitmq/password in shared mode."
  value       = module.rabbitmq.secret_arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret holding the admin password; it carries no topology suffix. This is the value an External Secrets Operator ExternalSecret references to populate the broker password in the chart's Secret."
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
  description = "Full AMQP URI exactly as AmazonMQ reports it, amqps://host:5671, in both modes. The one to use when an AMQPS client wants a single connection string rather than a split host/port/scheme."
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
# Verified against fetcher-helm 3.1.0 (appVersion 3.0.2), values.yaml
# `common.configmap` (the RabbitMQ block) and `secrets:`, rendered by
# templates/common/configmap.yaml.
#
# ┌──────────────────────────────────────────────────────────────────────────┐
# │ THE PORT VARIABLES ARE THE OPPOSITE WAY ROUND FROM MIDAZ.                 │
# │                                                                          │
# │            AMQP(S) port          management HTTP port                    │
# │   midaz    RABBITMQ_PORT_HOST    RABBITMQ_PORT_AMQP                      │
# │   fetcher  RABBITMQ_PORT_AMQP    RABBITMQ_PORT_HOST                      │
# └──────────────────────────────────────────────────────────────────────────┘
#
# values.yaml ships RABBITMQ_PORT_AMQP: "5672", RABBITMQ_PORT_HOST: "15672" and
# RABBITMQ_HEALTH_CHECK_URL: "http://rabbitmq:15672" — the health check URL uses
# the same number as PORT_HOST, which is what pins the mapping down. reporter
# uses the identical convention; midaz is the outlier of the three.
#
# RABBITMQ_URI is a SCHEME, not a URI. "amqps" is mandatory: AmazonMQ for
# RabbitMQ publishes no plaintext AMQP listener, so the chart default "amqp"
# cannot connect at all.
#
# RABBITMQ_HEALTH_CHECK_URL is emitted with no port: AmazonMQ serves the
# management API over HTTPS on 443, which is the scheme default.
#
# NOT emitted here, on purpose:
#   RABBITMQ_DEFAULT_PASS  — read from secret_name by External Secrets.
#   RABBITMQ_FETCHER_WORK_QUEUE / RABBITMQ_JOB_EVENTS_EXCHANGE /
#     RABBITMQ_NUMBERS_OF_WORKERS — application topology and tuning, and they
#     live in worker.configmap rather than common.configmap. AmazonMQ creates no
#     queues or exchanges; templates/bootstrap-rabbitmq.yaml does, over the
#     management API.
#   RABBITMQ_ERLANG_COOKIE — only meaningful for the bundled broker.
#
# DESTINATION NOTE: every key below belongs in `common.configmap` EXCEPT
# RABBITMQ_DEFAULT_USER, which this chart keeps in the top-level `secrets:` map.
################################################################################

output "helm_values" {
  description = "fetcher chart env vars this broker fills in. All keys merge into common.configmap except RABBITMQ_DEFAULT_USER, which the chart keeps under the top-level secrets map. The fetcher chart already ships rabbitmq.enabled = false, so nothing has to be turned off."
  value = {
    RABBITMQ_URI  = "amqps"
    RABBITMQ_HOST = module.rabbitmq.endpoint

    # NOT a copy-paste error — see the table in the header. PORT_AMQP is the
    # AMQPS port and PORT_HOST is the management port, the reverse of midaz.
    RABBITMQ_PORT_AMQP = tostring(module.rabbitmq.port)
    RABBITMQ_PORT_HOST = tostring(var.console_port)

    RABBITMQ_HEALTH_CHECK_URL = "https://${module.rabbitmq.endpoint}"

    # Belongs under the top-level `secrets:` map, not `common.configmap`.
    RABBITMQ_DEFAULT_USER = var.mq_admin_user
  }
}
