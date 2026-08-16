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
  description = "EKS cluster whose node security group was looked up. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to br-sfn."
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
  description = "ARN of the Secrets Manager secret holding the admin password: br-sfn-{env}-rabbitmq/password in dedicated mode, shared-{env}-rabbitmq/password in shared mode."
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
# Verified against br-sfn chart 1.1.0 (appVersion 1.0.0-beta.1).
#
# The br-sfn chart has NO fixed env allowlist: <component>.configmap and
# <component>.secrets are emitted VERBATIM (README.md:66-72). The chart therefore
# only *names* the variables its own templates read, and for AMQP it names
# exactly ONE, on exactly ONE rail — and that one is a SECRET:
#
#   values-template.yaml:80   correios.secrets.RABBITMQ_URL
#
# A grep for RABBITMQ, AMQP or MQ_ over the entire chart returns that line plus
# three prose mentions of the external-infra contract, and nothing else. There is
# no RABBITMQ_HOST, no RABBITMQ_PORT, no RABBITMQ_URI/PROTOCOL scheme pair — none
# of the shape products/midaz/rabbitmq emits.
#
# TERRAFORM CANNOT FILL A SECRET. RABBITMQ_URL is a complete connection URL with
# the password inside it, and this repository never emits a password: the
# password lives only in Secrets Manager, read by External Secrets. Splitting the
# URL is not an option either, because the chart offers no host/port keys to
# split it into.
#
# So the operator assembles it, from `endpoint`, `port`, `admin_username` and the
# password read from `secret_name`:
#
#   correios:
#     secrets:
#       RABBITMQ_URL: "amqps://<user>:<password>@<endpoint>:5671/"
#
# amqps and 5671 are not choices: AmazonMQ for RabbitMQ publishes NO plaintext
# AMQP listener. `endpoint` is the raw broker host, which is also mandatory — the
# broker certificate covers *.mq.{region}.on.aws only.
#
# TWO THINGS TO GET RIGHT WHEN ASSEMBLING IT
#
# 1. THE PASSWORD MUST BE URL-SAFE. It is being interpolated into a URL. The
#    chart states this rule for Postgres in the same words ("no @ : / ? # %",
#    README.md:51) and it applies verbatim here. The rabbitmq-amazonmq module
#    generates the password with override_special = "!#$%^&*()-_+{}<>?", which
#    INCLUDES ? and % — see README.md, "The generated password may not be
#    URL-safe". Verify before the first release; percent-encode or rotate.
# 2. There is only ONE broker user. The module creates the admin user; any
#    per-rail user is created on the broker itself, outside Terraform.
#
#   # CONFIRMAR no chart: whether any rail other than correios speaks AMQP. The
#   # chart's infra contract lists RabbitMQ as external for the whole monorepo
#   # (Chart.yaml:43-45, README.md:76), but correios is the only component with an
#   # AMQP key. If spb/spi/siloc also use the broker, their variable names live in
#   # the br-sfn application repository, not in the chart.
#
# The vhost is another gap: AmazonMQ creates the default "/" vhost and the URL
# above uses it. Which vhost each rail should use is an application decision.
################################################################################

output "helm_values" {
  description = "EMPTY ON PURPOSE. The br-sfn chart's only AMQP variable is correios.secrets.RABBITMQ_URL — a full connection URL containing the password — and this repository never emits a password. Assemble it from endpoint, port, admin_username and the password behind secret_name; the exact template and the URL-safety warning are in the header of this file and in README.md. This chart ships no RabbitMQ subchart, so there is nothing to disable."
  value       = {}
}
