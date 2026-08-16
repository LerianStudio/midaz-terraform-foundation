################################################################################
# Contract variables (identical across every Lerian datastore module)
################################################################################

variable "product" {
  description = "Lerian product this broker belongs to (e.g. midaz, reporter). Use \"shared\" for the tier owned by products/shared-resources/rabbitmq — NOT \"lerian\", which labels the foundation (lerian-{env}-vpc, lerian-{env}-eks)."
  type        = string
}

variable "environment" {
  description = "Deployment environment. One of dev, stg or prd."
  type        = string

  validation {
    condition     = contains(["dev", "stg", "prd"], var.environment)
    error_message = "The environment must be one of: dev, stg, prd."
  }
}

# WARNING: this is the Lerian sharing mode, NOT the AmazonMQ deployment mode.
# The AmazonMQ SINGLE_INSTANCE / CLUSTER_MULTI_AZ knob is broker_deployment_mode.
variable "mode" {
  description = "\"dedicated\" creates an AmazonMQ broker for this product. \"shared\" creates nothing and only resolves the endpoints/secret of the shared broker owned by products/shared-resources/rabbitmq. This has nothing to do with broker_deployment_mode."
  type        = string
  default     = "dedicated"

  validation {
    condition     = contains(["dedicated", "shared"], var.mode)
    error_message = "The mode must be either 'dedicated' or 'shared'."
  }
}

variable "extra_tags" {
  description = "Additional tags merged on top of the standard Lerian tag set."
  type        = map(string)
  default     = {}
}

variable "vpc_name" {
  description = "tag:Name of the VPC that hosts the broker. When empty, defaults to \"lerian-{environment}-vpc\"."
  type        = string
  default     = ""
}

variable "subnet_tag_type" {
  description = "Value of the tag:Type used to select the subnets the broker is placed in. The pre-v2 examples/aws/amazonmq stack used \"private\"."
  type        = string
  default     = "database"
}

################################################################################
# Ingress
#
# The three variables below implement ONE rule, worded identically in all five
# Lerian datastore modules. Do not diverge them.
################################################################################

variable "allowed_security_group_ids" {
  description = "Security group IDs allowed to reach the datastore port. Any entry here or in allowed_cidr_blocks disables the VPC CIDR fallback: only what is listed is allowed, and nothing is added on top. When both lists are empty the fallback in allow_vpc_cidr_ingress decides."
  type        = list(string)
  default     = []
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed to reach the datastore port. Any entry here or in allowed_security_group_ids disables the VPC CIDR fallback: only what is listed is allowed, and nothing is added on top. When both lists are empty the fallback in allow_vpc_cidr_ingress decides."
  type        = list(string)
  default     = []
}

variable "allow_vpc_cidr_ingress" {
  description = "FALLBACK ONLY. Allow the whole VPC CIDR to reach the datastore port when allowed_cidr_blocks and allowed_security_group_ids are BOTH empty - the pre-refactor behaviour, kept so a migrated stack does not silently lose connectivity. It is never applied on top of a non-empty allow list. Set false to make empty allow lists mean no ingress at all; a check block then warns that the datastore is unreachable."
  type        = bool
  default     = true
}

variable "port" {
  description = "AMQPS port the broker listens on. AmazonMQ for RabbitMQ exposes no plaintext AMQP listener, so this is 5671 and there is no reason to change it. Ingress rules are scoped to this port instead of the every-protocol ip_protocol = \"-1\" the module used before."
  type        = number
  default     = 5671
}

variable "console_port" {
  description = "Port of the RabbitMQ management console and management HTTP API. AmazonMQ serves both over HTTPS on 443. Only used when enable_console_ingress is true."
  type        = number
  default     = 443
}

variable "enable_console_ingress" {
  description = "Also open console_port (443) to the resolved ingress sources, so the RabbitMQ management console and management HTTP API stay reachable from inside the VPC. Was implicitly open before, because ingress was written with ip_protocol = \"-1\". Set false to allow AMQPS only."
  type        = bool
  default     = true
}

variable "shared_broker_name" {
  description = <<-EOT
    Name of the AmazonMQ broker resolved when mode = "shared". Empty (the
    default) derives "shared-{environment}-rabbitmq-single".

    THE SUFFIX IS NOT OPTIONAL AND CANNOT BE DISCOVERED. append_deployment_suffix
    is true on both sides, so the shared broker is named
    shared-{env}-rabbitmq-SINGLE or shared-{env}-rabbitmq-CLUSTER depending on
    the topology products/shared-resources/rabbitmq deployed. data "aws_mq_broker"
    matches the name EXACTLY and the AWS provider ships no list/filter data
    source for MQ, so the topology has to be declared here.

    The derived default matches the shared-resources/rabbitmq dev tfvars
    (rabbitmq_broker_deployment_mode = "SINGLE_INSTANCE"). The stg and prd
    tfvars ship CLUSTER_MULTI_AZ, so a shared consumer there sets
    shared_broker_name = "shared-{env}-rabbitmq-cluster".

    Getting it wrong is loud, not silent: the plan fails naming the broker it
    searched for. The secret is unaffected either way — it never carries the
    suffix.
  EOT
  type        = string
  default     = ""
}

variable "shared_secret_name" {
  description = "Override for the Secrets Manager secret name resolved in shared mode. Defaults to \"shared-{environment}-rabbitmq/password\"."
  type        = string
  default     = ""
}

################################################################################
# Broker engine and sizing (migrated from the pre-v2 examples/aws/amazonmq stack)
################################################################################

# Renamed from `deployment_mode` so it can never be confused with `var.mode`
# above. This is the AWS AmazonMQ topology knob.
variable "broker_deployment_mode" {
  description = "AmazonMQ topology. Valid values: SINGLE_INSTANCE, CLUSTER_MULTI_AZ. ACTIVE_STANDBY_MULTI_AZ is not supported (ActiveMQ only). Unrelated to var.mode."
  type        = string
  default     = "CLUSTER_MULTI_AZ"

  validation {
    condition     = contains(["SINGLE_INSTANCE", "CLUSTER_MULTI_AZ"], var.broker_deployment_mode)
    error_message = "The broker_deployment_mode must be either 'SINGLE_INSTANCE' or 'CLUSTER_MULTI_AZ'. Note: 'ACTIVE_STANDBY_MULTI_AZ' is not supported (ActiveMQ only)."
  }
}

variable "append_deployment_suffix" {
  description = "Append -single / -cluster to the broker name. Keeps the side-by-side upgrade procedure in docs/UPGRADE-GUIDE.md possible: the old and the new broker can coexist. Does not affect the secret or the security group, which is why the shared SECRET resolves without knowing the topology while the shared BROKER lookup has to declare it — see shared_broker_name."
  type        = bool
  default     = true
}

variable "engine_type" {
  description = "Broker engine. This module targets RabbitMQ; the preconditions assume it."
  type        = string
  default     = "RabbitMQ"
}

variable "engine_version" {
  description = "Version of the broker engine."
  type        = string
  default     = "3.13"
}

variable "host_instance_type" {
  description = "Broker instance type. The RabbitMQ engine only accepts the mq.m5.* and mq.m7g.* families, in BOTH deployment modes; mq.t2.* / mq.t3.* are ActiveMQ-only and fail CreateBroker. mq.m7g.medium is the smallest RabbitMQ type. A plan-time precondition enforces this."
  type        = string
  default     = "mq.m5.large"
}

variable "publicly_accessible" {
  description = "Enable public access to the broker."
  type        = bool
  default     = false
}

variable "auto_minor_version_upgrade" {
  description = "Enable automatic upgrades to new minor versions of the broker engine."
  type        = bool
  default     = true
}

variable "apply_immediately" {
  description = "Apply broker modifications immediately instead of waiting for the maintenance window."
  type        = bool
  default     = true
}

variable "enable_general_logs" {
  description = "Export the RabbitMQ general log to CloudWatch Logs."
  type        = bool
  default     = true
}

variable "mq_admin_user" {
  description = "Administrator username for the broker."
  type        = string
  default     = "rabbitmqadmin"
  sensitive   = true
}
