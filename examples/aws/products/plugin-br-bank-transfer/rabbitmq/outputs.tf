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
  description = "EKS cluster whose node security group was looked up. Should equal the cluster_name output of infra-base/eks. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to plugin-br-bank-transfer."
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
  description = "ARN of the Secrets Manager secret holding the admin password: plugin-br-bank-transfer-{env}-rabbitmq/password in dedicated mode, shared-{env}-rabbitmq/password in shared mode."
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
# Verified against chart 1.5.0 (appVersion 1.2.1), templates/configmap.yaml,
# templates/secrets.yaml and templates/deployment.yaml.
#
# THIS DATASTORE IS OPTIONAL AND OFF BY DEFAULT, TWICE OVER:
#
#   values.yaml   rabbitmq.enabled: false                (no bundled subchart)
#   configmap     RABBITMQ_ENABLED default "false"       (no client either)
#
# and templates/configmap.yaml renders RABBITMQ_URL and RABBITMQ_EXCHANGE only
# inside {{- if eq (toString ... RABBITMQ_ENABLED) "true" }}. So provisioning the
# broker without flipping RABBITMQ_ENABLED leaves an idle ~USD 100/month broker
# and an application that never connects to it. RABBITMQ_ENABLED is emitted below
# for exactly that reason: applying this directory IS the decision that makes it
# true.
#
# The whole block is also single-tenant only — it sits inside
# {{- if not $multiTenantEnabled }}.
#
# RABBITMQ_URL IS NOT EMITTED, AND THE REASON IS NOT THE USUAL ONE.
#
# It is the only connection variable the chart has (no host, no port, no user
# key), and it embeds the credentials, so Terraform building it would write a
# cleartext password into state — the usual reason. But the escape hatch that
# works for this product's MongoDB sibling does NOT work here:
#
#   documentdb: MONGO_URI is emitted by _helpers.tpl as an explicit `env:` entry
#               with a `value:`, so the kubelet expands $(MONGO_PASSWORD)
#               against the preceding secretKeyRef entry. No password in state.
#
#   rabbitmq:   RABBITMQ_URL is a ConfigMap key delivered with `envFrom:`, and
#               Kubernetes does NOT expand $(VAR) in envFrom-sourced values —
#               only in env[].value. The literal string "$(RABBITMQ_PASSWORD)"
#               reaches the application.
#
# The chart's own default for RABBITMQ_URL uses that very placeholder
# (amqp://bank_transfer:$(RABBITMQ_PASSWORD)@<release>-rabbitmq...), which means
# the default cannot work as written even with the bundled subchart. Reported
# upstream; not something this stack can fix.
#
# Assemble RABBITMQ_URL in the secret store instead, from secret_name plus the
# amqp_endpoint output — and note the scheme must be amqps, not the chart
# default's amqp: AmazonMQ publishes no plaintext AMQP listener at all.
#
#     amqp_endpoint  ->  amqps://host:5671
#     RABBITMQ_URL   ->  amqps://USER:URLENCODED_PW@host:5671/
#
# Then override it as a ConfigMap value (bankTransfer.configmap.RABBITMQ_URL) or
# through bankTransfer.extraEnvVars. Note the ordering trap if you put it in the
# Secret instead: templates/deployment.yaml lists secretRef BEFORE configMapRef
# in envFrom, so a ConfigMap key of the same name wins.
#
# NOT emitted here, on purpose:
#   RABBITMQ_URL — see above.
#   RABBITMQ_PASSWORD / RABBITMQ_EVENT_SIGNING_SECRET — credentials, read from
#     secret_name (and from the application's own secret store) by External
#     Secrets.
#   RABBITMQ_EXCHANGE — application topology ("bank_transfer.lifecycle"), not
#     infrastructure. Terraform creates no exchanges; the broker is empty on
#     first boot, and the bundled-subchart path seeds it from
#     files/rabbitmq/load_definition.json, which AmazonMQ cannot consume.
#     # CONFIRMAR com o time: on AmazonMQ the exchanges, queues and bindings in
#     # files/rabbitmq/load_definition.json have to be created by some other
#     # mechanism — AmazonMQ does not accept a definitions file.
################################################################################

output "helm_values" {
  description = "plugin-br-bank-transfer chart env vars this broker fills in, ready to merge into bankTransfer.configmap. Deliberately small: this chart's only connection variable is RABBITMQ_URL, which embeds credentials and cannot be built by Terraform — see the header and the amqp_endpoint output. Pair it with rabbitmq.enabled = false so the bundled subchart is not deployed alongside AmazonMQ (the subchart is already off by default)."
  value = {
    RABBITMQ_ENABLED = "true"
  }
}
