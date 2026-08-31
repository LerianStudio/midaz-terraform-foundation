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
  description = "EKS cluster whose node security group was looked up. Should equal the cluster_name output of infra-base/eks. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to plugin-bc-correios."
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
  description = "ARN of the Secrets Manager secret holding the admin password: plugin-bc-correios-{env}-rabbitmq/password in dedicated mode, shared-{env}-rabbitmq/password in shared mode."
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
# Verified against plugin-bc-correios-helm 2.2.0 (appVersion 1.2.0),
# templates/configmap.yaml (the RabbitMQ block), templates/secrets.yaml and
# templates/deployment.yaml.
#
# ┌──────────────────────────────────────────────────────────────────────────┐
# │ BLOCKER: THE INIT CONTAINER HARDCODES PORT 5672 AND AMAZONMQ DOES NOT     │
# │ LISTEN ON IT.                                                            │
# │                                                                          │
# │ templates/deployment.yaml, wait-for-dependencies:                        │
# │                                                                          │
# │     # Wait for RabbitMQ (AMQP port)                                      │
# │     wait_for_service "$RABBITMQ_HOST" "5672"                             │
# │                                                                          │
# │ The port is a literal, not a value. AmazonMQ for RabbitMQ publishes only  │
# │ AMQPS on 5671, so this TCP check can never succeed against a managed      │
# │ broker: the init container retries for its full 300-second timeout and    │
# │ then exits 1, and the pod never reaches the application container.        │
# │                                                                          │
# │ No Terraform value fixes this. It needs a CHART change — the literal has  │
# │ to become a configurable port. Until then, either keep the bundled        │
# │ in-cluster broker for this product or patch the init container.           │
# │                                                                          │
# │ Reported rather than worked around: emitting a fake RABBITMQ_HOST that    │
# │ happens to answer on 5672 would be worse than a loud failure.             │
# └──────────────────────────────────────────────────────────────────────────┘
#
# THERE IS NO PORT VARIABLE AT ALL in this chart's RabbitMQ surface. The full
# surface is RABBITMQ_USER and RABBITMQ_HOST in the ConfigMap, plus RABBITMQ_PASS
# and RABBITMQ_URL in the Secret. RABBITMQ_HOST exists ONLY for the init
# container's TCP check; the application connects using RABBITMQ_URL.
#
# RABBITMQ_URL IS A SECRET AND TERRAFORM MUST NOT EMIT IT. It is a full AMQP URI
# and therefore carries the password. Assemble it in the ExternalSecret from the
# broker password in secret_name and the host below:
#
#   amqps://<RABBITMQ_USER>:<password>@<endpoint>:5671/
#
# The `amqp_endpoint` output of this stack is the same URI without credentials
# (amqps://host:5671), which is the safe half to copy. Note "amqps", not "amqp":
# AmazonMQ publishes no plaintext listener.
#
# NOT emitted here, on purpose:
#   RABBITMQ_PASS / RABBITMQ_URL — credentials, read from secret_name by External
#     Secrets.
#   RABBITMQ_ERLANG_COOKIE       — only meaningful for the bundled broker.
################################################################################

output "helm_values" {
  description = "plugin-bc-correios chart env vars this broker fills in, ready to merge into the bc-correios.configmap block. INCOMPLETE BY NECESSITY: the application connects through RABBITMQ_URL, which is a Secret because it embeds the password, and the init container's hardcoded 5672 blocks AmazonMQ entirely until the chart is changed. See the header."
  value = {
    RABBITMQ_HOST = module.rabbitmq.endpoint
    RABBITMQ_USER = var.mq_admin_user
  }
}
