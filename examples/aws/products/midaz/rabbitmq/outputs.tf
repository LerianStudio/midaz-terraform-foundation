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
  description = "EKS cluster whose node security group was looked up. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to midaz."
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
  description = "ARN of the Secrets Manager secret holding the admin password: midaz-{env}-rabbitmq/password in dedicated mode, shared-{env}-rabbitmq/password in shared mode."
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
  description = "Administrator username configured on the broker. It is the ADMIN identity, consumed by the chart's bootstrap Job as RABBITMQ_ADMIN_USER — not the user the workload authenticates as, which the Job creates. Read from the stack variable rather than from the module output, which is marked sensitive and would redact anything it is merged into."
  value       = var.mq_admin_user
}

################################################################################
# Helm handoff
#
# The exact env var names the midaz chart reads, so wiring the release is a copy,
# not a translation. Verified against chart 8.7.0 (appVersion 3.8.0),
# templates/ledger/configmap.yaml.
#
# KEYED BY CHART COMPONENT: the chart gives each component its own ConfigMap, so the
# destination is part of this output. Everything here lands on the LEDGER deployment
# — the CRM deployment has no RabbitMQ variables, which is why there is no "crm"
# entry rather than an empty one.
#
# The same shape is produced by pkg/infra/chartmap.go for shared mode. The two must
# agree: TestMidazShapeIsTheSameInBothModes fails when they drift.
#
# THE TWO PORT VARIABLES ARE NAMED BACKWARDS IN THE CHART. This is not a typo
# below — it is the chart's own convention, and the ledger init container reads
# them that way:
#
#   RABBITMQ_PORT_HOST  ->  the AMQP(S) port      (5672 upstream, 5671 here)
#   RABBITMQ_PORT_AMQP  ->  the management HTTP port (15672 upstream, 443 here)
#
# RABBITMQ_URI and RABBITMQ_PROTOCOL are SCHEMES, not URIs:
#   RABBITMQ_URI      "amqps" — AmazonMQ publishes no plaintext AMQP listener, so
#                     the chart default "amqp" cannot connect at all.
#   RABBITMQ_PROTOCOL "https" — the management API is HTTPS on 443. The chart
#                     builds RABBITMQ_HEALTH_CHECK_URL from this, and its https
#                     branch deliberately omits the port (printf "%s://%s"),
#                     which is correct for 443.
#
# NOT emitted here, on purpose:
#   RABBITMQ_DEFAULT_PASS / RABBITMQ_CONSUMER_PASS — read from secret_name by
#     External Secrets. The chart marks both `required` and fails the install when
#     they are empty, so they must be wired before the first release.
#   RABBITMQ_VHOST — AmazonMQ creates the default "/" vhost, but which vhost the
#     ledger should use is a chart decision, and the chart default is "".
#   RABBITMQ_DEFAULT_USER / RABBITMQ_CONSUMER_USER — the module creates ONE broker
#     user, the administrator. templates/bootstrap-rabbitmq.yaml connects as it and
#     creates the two scoped users the workload uses, "transaction" and "consumer";
#     "transaction" is the chart default for RABBITMQ_DEFAULT_USER. Emitting the
#     administrator here overrode that default and produced
#     "403 username or password not allowed" against a broker that was up.
################################################################################

output "helm_values" {
  description = "midaz chart env vars this broker fills in, keyed by CHART COMPONENT. Merge each entry into the matching <component>.configmap block. `crm` is absent because the CRM deployment has no RabbitMQ variable. Pair it with rabbitmq.enabled = false so the bundled subchart is not deployed alongside AmazonMQ. Note the chart has NO rabbitmq.external key — enabled = false is the whole switch."
  value = {
    ledger = {
      RABBITMQ_URI      = "amqps"
      RABBITMQ_PROTOCOL = "https"
      RABBITMQ_HOST     = module.rabbitmq.endpoint

      # Named backwards on purpose — see the header.
      RABBITMQ_PORT_HOST = tostring(module.rabbitmq.port)
      RABBITMQ_PORT_AMQP = tostring(var.console_port)
    }
  }
}
