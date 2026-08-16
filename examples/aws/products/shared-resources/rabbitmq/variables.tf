################################################################################
# Stack identity
#
# There is no `mode` variable in this root, deliberately. The module call is
# pinned to mode = "dedicated" because this stack is the OWNER of the shared
# broker — see the header of main.tf. The AmazonMQ topology knob is
# var.broker_deployment_mode, further down, and it is a different axis.
#
# There is no `rabbitmq_enabled` toggle either. Enabling this datastore is
# applying this directory.
#
# There is no `shared_broker_name` variable either: that one is read only in
# shared mode, on the CONSUMER side. This stack is what decides the name the
# consumer has to declare — see var.broker_deployment_mode.
################################################################################

variable "region" {
  description = "AWS region the shared broker is created in. Must be the region the infra-base VPC lives in."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", var.region))
    error_message = "The region must be a valid AWS region identifier, e.g. us-east-1 or sa-east-1."
  }
}

variable "product" {
  description = "Product label this broker carries. Keep the default \"shared\": that is what makes the derived name (shared-{env}-rabbitmq[-single|-cluster]) and the derived secret path (shared-{env}-rabbitmq/password) match exactly what rabbitmq-amazonmq looks up when a product sets mode = \"shared\". Changing it makes every shared consumer unresolvable. The FOUNDATION stacks keep the \"lerian\" label (lerian-{env}-vpc, lerian-{env}-eks) because they have no dedicated counterpart; this DATASTORE tier carries \"shared\"."
  type        = string
  default     = "shared"

  validation {
    condition     = var.product == "shared"
    error_message = "The product must be \"shared\". The shared mode of rabbitmq-amazonmq derives the broker name as \"shared-{environment}-rabbitmq-{single|cluster}\" and the secret as \"shared-{environment}-rabbitmq/password\". A different product here produces a broker no shared consumer can find. If you genuinely want a second broker, that is a product root stack with mode = \"dedicated\", not this one."
  }
}

variable "environment" {
  description = "Deployment environment. One of dev, stg or prd."
  type        = string

  validation {
    condition     = contains(["dev", "stg", "prd"], var.environment)
    error_message = "The environment must be one of: dev, stg, prd."
  }
}

variable "extra_tags" {
  description = "Additional tags merged on top of the standard Lerian tag set (Product, Environment, ManagedBy, Repository)."
  type        = map(string)
  default     = {}
}

################################################################################
# Network context
#
# Both names are OWNED BY the infra-base FOUNDATION and therefore carry the
# "lerian" product label — not "shared", which labels this datastore tier.
################################################################################

variable "vpc_name" {
  description = "tag:Name of the VPC the broker is placed in. Leave empty (the default) to DERIVE \"lerian-{environment}-vpc\", which is what infra-base/vpc creates and exports as its vpc_name output."
  type        = string
  default     = ""
}

variable "subnet_tag_type" {
  description = "Value of the tag:Type used to select the subnets the broker is placed in. \"database\" keeps it aligned with the other four datastores in this tier."
  type        = string
  default     = "database"
}

################################################################################
# Ingress — the part the shared model lives or dies on
#
# A product running with mode = "shared" gets security_group_id = null from its
# module: it creates no security group and therefore cannot authorise itself.
# Opening the shared broker is exclusively this stack's job.
################################################################################

variable "allowed_security_group_ids" {
  description = "Extra security group IDs allowed to reach the broker. Merged with the EKS node security group when eks_node_security_group_lookup_enabled is true."
  type        = list(string)
  default     = []
}

variable "allowed_cidr_blocks" {
  description = "Extra CIDR blocks allowed to reach the broker. Merged with the private subnet CIDRs when allow_private_subnet_cidr_ingress is true."
  type        = list(string)
  default     = []
}

variable "allow_private_subnet_cidr_ingress" {
  description = "Allow the CIDR blocks of the Type=private subnets to reach the broker. This is the DEFAULT ingress path and the reason this stack can be applied before infra-base/eks exists. It is strictly tighter than the VPC-CIDR fallback the module ships, which additionally covers the public subnets. Set it to false once the EKS node security group is being resolved, to move to security-group-only ingress."
  type        = bool
  default     = true
}

variable "eks_node_security_group_lookup_enabled" {
  description = "Resolve the EKS node security group by tag and allow it on the broker. Safe to leave true before infra-base/eks exists: the lookup uses data \"aws_security_groups\" (PLURAL), which returns an empty list rather than failing the plan."
  type        = bool
  default     = true
}

variable "eks_cluster_name" {
  description = "Name of the EKS cluster whose node security group is resolved. Leave empty (the default) to DERIVE \"lerian-{environment}-eks\" — the cluster belongs to infra-base and carries the \"lerian\" product label, NOT \"shared\". The lookup matches by tag:Name = \"{cluster}-node\"."
  type        = string
  default     = ""
}

variable "allow_vpc_cidr_ingress" {
  description = "Passed straight to the module as its allow_vpc_cidr_ingress input. FALLBACK ONLY: applied exclusively when both allowed_cidr_blocks and allowed_security_group_ids resolve empty; any entry in either list wins outright and the VPC CIDR is never added on top. Kept false here so an empty allow list trips the module's check \"ingress_is_reachable\" instead of quietly widening to a CIDR that includes the public subnets."
  type        = bool
  default     = false
}

################################################################################
# Ports
################################################################################

variable "port" {
  description = "AMQPS port the broker listens on. AmazonMQ for RabbitMQ exposes NO plaintext AMQP listener, so this is 5671 and there is no reason to change it."
  type        = number
  default     = 5671
}

variable "console_port" {
  description = "Port of the RabbitMQ management console and management HTTP API. AmazonMQ serves both over HTTPS on 443."
  type        = number
  default     = 443
}

variable "enable_console_ingress" {
  description = "Also open console_port (443) to the resolved ingress sources, so the management console and the management HTTP API stay reachable from inside the VPC. True reproduces what the module's pre-v2 ip_protocol = \"-1\" rules allowed implicitly; false narrows the broker to AMQPS only. The midaz ledger's RABBITMQ_HEALTH_CHECK_URL targets that API, so turning this off breaks the chart's broker health check as well as the console."
  type        = bool
  default     = true
}

################################################################################
# Broker engine and topology
#
# THIS IS THE AWS TOPOLOGY AXIS, NOT THE LERIAN SHARING AXIS. The module always
# runs with mode = "dedicated" here — see the header of main.tf.
################################################################################

variable "broker_deployment_mode" {
  description = <<-EOT
    AmazonMQ topology of the shared broker: SINGLE_INSTANCE or CLUSTER_MULTI_AZ.
    Unrelated to the module's `mode`, which is pinned to "dedicated" here.

    THIS VALUE IS PART OF THE CROSS-STACK CONTRACT. With
    append_deployment_suffix = true the broker is named
    shared-{env}-rabbitmq-single or shared-{env}-rabbitmq-cluster, and a product
    consuming it with mode = "shared" must DECLARE that suffix through its own
    shared_broker_name — data "aws_mq_broker" matches the name exactly and the
    AWS provider ships no list/filter data source for MQ, so it cannot be
    discovered.

      SINGLE_INSTANCE   -> consumer leaves shared_broker_name = "" (derived default)
      CLUSTER_MULTI_AZ  -> consumer sets  "shared-{env}-rabbitmq-cluster"

    Changing this is therefore a BREAKING CHANGE for every shared consumer, and
    their plans fail naming the broker they searched for rather than degrading
    silently. The secret and the security group never carry the suffix, so those
    resolve either way.

    The topology does NOT constrain host_instance_type: every RabbitMQ instance
    type supports both modes. CLUSTER_MULTI_AZ costs three broker nodes instead
    of one — that is the whole dev-to-prd cost jump.
  EOT
  type        = string
  default     = "SINGLE_INSTANCE"

  validation {
    condition     = contains(["SINGLE_INSTANCE", "CLUSTER_MULTI_AZ"], var.broker_deployment_mode)
    error_message = "The broker_deployment_mode must be either 'SINGLE_INSTANCE' or 'CLUSTER_MULTI_AZ'. ACTIVE_STANDBY_MULTI_AZ is ActiveMQ only."
  }
}

variable "append_deployment_suffix" {
  description = "Append -single / -cluster to the broker name. Keep it true: it is what allows a side-by-side SINGLE_INSTANCE -> CLUSTER_MULTI_AZ migration, which on a SHARED broker is the only safe kind — the two brokers coexist while consumers are moved one at a time. Setting it false makes the derived shared_broker_name default wrong for every consumer."
  type        = bool
  default     = true
}

variable "engine_version" {
  description = "RabbitMQ engine version of the shared broker."
  type        = string
  default     = "3.13"
}

variable "host_instance_type" {
  description = "Instance type of the shared broker. The RabbitMQ engine only accepts the mq.m5.* and mq.m7g.* families, and accepts all of them in BOTH deployment modes; mq.t2.* / mq.t3.* are ActiveMQ-only and AWS rejects them for RabbitMQ in every mode, SINGLE_INSTANCE included. mq.m7g.medium is the smallest RabbitMQ type there is — roughly USD 100/month — which is why it is the default and why RabbitMQ has no cheap corner. The module enforces the family at plan time."
  type        = string
  default     = "mq.m7g.medium"
}

variable "mq_admin_user" {
  description = "Administrator username of the shared broker. Deliberately NOT marked sensitive at this level: the module marks its own copy sensitive, and reading it back through that output would redact the whole helm_values map. A product consuming with mode = \"shared\" declares this value on its own side rather than reading it from the broker, so keep both at the default \"rabbitmqadmin\". The module creates ONE broker user; per-product users are created on the broker itself, outside Terraform."
  type        = string
  default     = "rabbitmqadmin"
}

variable "auto_minor_version_upgrade" {
  description = "Let AmazonMQ apply minor engine upgrades to the shared broker automatically. Consider false in prd: an unattended broker restart is a message-loss window for every consuming product that is not using publisher confirms."
  type        = bool
  default     = true
}

variable "apply_immediately" {
  description = "Apply broker modifications immediately instead of waiting for the maintenance window. Consider leaving this false on a shared broker: an immediate change is an immediate disruption for every consuming product at once."
  type        = bool
  default     = false
}

variable "enable_general_logs" {
  description = "Export the RabbitMQ general log of the shared broker to CloudWatch Logs."
  type        = bool
  default     = true
}
