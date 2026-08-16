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
  description = "EKS cluster whose node security group was looked up. Should equal the cluster_name output of infra-base/eks. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to matcher."
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
  description = "ARN of the Secrets Manager secret holding the admin password: matcher-{env}-rabbitmq/password in dedicated mode, shared-{env}-rabbitmq/password in shared mode."
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
# Helm handoff — DELIBERATELY EMPTY
#
# THERE IS NO CHART TO MAP TO. infrastructure/K8S/helm/charts/matcher/ contains
# exactly one thing:
#
#     matcher/
#     └── charts/
#         ├── postgresql-16.3.5.tgz
#         ├── valkey-2.4.7.tgz
#         └── rabbitmq-2.1.11.tgz
#
# No Chart.yaml. No values.yaml. No values-template.yaml. No templates/. No
# Chart.lock. Only the vendored dependency tarballs a `helm dependency update`
# left behind, from a chart whose own source is not in this repository.
#
# rabbitmq-2.1.11.tgz is the groundhog2k RabbitMQ chart — the same version midaz and
# plugin-br-bank-transfer vendor. Solid evidence of a `rabbitmq` dependency. Note
# that plugin-br-bank-transfer vendors the same tarball while shipping the subchart
# DISABLED, so a vendored tarball proves the dependency is DECLARED, not that the
# broker is required at runtime.
#
# # CONFIRMAR com o time: whether Matcher actually needs a broker, or whether this
# # tarball is a declared-but-disabled dependency like plugin-br-bank-transfer's.
# # At roughly USD 100/month for the smallest AmazonMQ RabbitMQ broker, the answer
# # decides whether this directory should be applied at all.
#
# What that means for this output: the resource names, the endpoints, the ports
# and the secret paths below are all real and verifiable — they come from AWS,
# not from a chart. The ENV VAR NAMES the Matcher application reads are not
# knowable from here, and this repository has already been bitten three times by
# assuming one chart's names apply to another:
#
#   - midaz removed REDIS_PORT in chart 3.0 and folds the port into REDIS_HOST;
#     notifications keeps them split. Same company, opposite shapes.
#   - RABBITMQ_PORT_HOST means the AMQP port in the midaz chart and the
#     MANAGEMENT port in the notifications chart. Same two names, swapped.
#   - The PostgreSQL host key is POSTGRES_HOST in two charts, DB_HOST in a third
#     and DB_ONBOARDING_HOST / DB_TRANSACTION_HOST in a fourth.
#
# An invented map would look authoritative and break in production. An empty one
# is honest and costs a five-minute conversation with the Matcher team.
#
# WHAT TO DO WHEN THE CHART LANDS:
#   1. Read its values.yaml and its configmap templates — not another product's.
#   2. Fill this output with the names that are actually there.
#   3. Delete this comment block and the "inferred composition" section of
#      ../README.md.
#
# For orientation only, NOT a recommendation to hardcode: midaz splits the
# connection into RABBITMQ_HOST plus two confusingly named port variables,
# notifications uses the same two names with the OPPOSITE meanings, and
# plugin-br-bank-transfer takes a single RABBITMQ_URL with the credentials inline.
# Whatever Matcher does, the scheme has to be amqps: AmazonMQ publishes no
# plaintext AMQP listener.
################################################################################

output "helm_values" {
  description = "EMPTY ON PURPOSE. The Matcher chart is not in this repository (only its vendored dependency tarballs are), so the env var names it reads cannot be verified. Inventing them would produce a map that looks authoritative and fails at runtime. Use the endpoint, port, username, secret_name and identifier outputs above to wire the release by hand, and fill this in once the chart is available. See the header of this file and the 'Inferred composition' section of ../README.md."
  value       = {}
}
