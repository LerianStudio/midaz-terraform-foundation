################################################################################
# Stack identity
################################################################################

variable "region" {
  description = "AWS region the broker is created in. Must be the region the infra-base VPC lives in."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", var.region))
    error_message = "The region must be a valid AWS region identifier, e.g. us-east-1 or sa-east-1."
  }
}

variable "product" {
  description = "Product this broker belongs to. Pinned to \"midaz\" by validation: the derived name (midaz-{env}-rabbitmq[-single|-cluster]) and the derived secret path (midaz-{env}-rabbitmq/password) ARE the cross-stack discovery contract. A different value here silently produces resources the midaz Helm release cannot find."
  type        = string
  default     = "midaz"

  validation {
    condition     = var.product == "midaz"
    error_message = "The product must be \"midaz\". This root stack is the midaz RabbitMQ broker; every name and secret path it produces is derived from it. To provision a broker for another product, copy this directory to examples/aws/products/<product>/rabbitmq instead."
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

# WARNING: this is the Lerian sharing mode, NOT the AmazonMQ deployment mode.
# The AmazonMQ SINGLE_INSTANCE / CLUSTER_MULTI_AZ knob is broker_deployment_mode.
variable "mode" {
  description = "\"dedicated\" creates an AmazonMQ broker owned by midaz (midaz-{env}-rabbitmq). \"shared\" creates nothing and resolves the broker owned by products/shared-resources/rabbitmq, looked up by name — see shared_broker_name, which carries the -single / -cluster topology suffix — plus the secret shared-{env}-rabbitmq/password. This has NOTHING to do with broker_deployment_mode, which is the AWS topology."
  type        = string
  default     = "dedicated"

  validation {
    condition     = contains(["dedicated", "shared"], var.mode)
    error_message = "The mode must be one of: dedicated, shared."
  }
}

variable "shared_broker_name" {
  description = <<-EOT
    Only read when mode = "shared". Name of the AmazonMQ broker owned by
    products/shared-resources/rabbitmq. Empty (the default) derives
    "shared-{environment}-rabbitmq-single".

    THIS IS THE ONE SHARED-MODE INPUT THAT IS NOT FULLY DERIVABLE, and the reason
    RabbitMQ needs a variable the other three datastores do not. The broker name
    carries a -single / -cluster topology suffix (append_deployment_suffix, true
    on both sides), data "aws_mq_broker" matches the name EXACTLY, and the AWS
    provider ships no list/filter data source for MQ — so the topology of the
    shared tier has to be declared, not discovered.

    The default matches the products/shared-resources/rabbitmq dev tfvars (SINGLE_INSTANCE). Its stg
    and prd tfvars ship CLUSTER_MULTI_AZ, so a midaz release consuming the shared
    broker there sets:

      shared_broker_name = "shared-stg-rabbitmq-cluster"

    Getting it wrong is loud, not silent: the plan fails naming the broker it
    searched for. The secret is unaffected either way — it never carries the
    suffix.
  EOT
  type        = string
  default     = ""
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
# "lerian" product label — not "midaz", and not "shared" either (that one labels
# the shared DATASTORE tier in products/shared-resources). Deriving them from module.naming here would
# produce midaz-{env}-vpc / midaz-{env}-eks, which do not exist — which is why
# this root stack does not call the naming module at all.
################################################################################

variable "vpc_name" {
  description = "tag:Name of the VPC the broker is placed in. Leave empty (the default) to DERIVE \"lerian-{environment}-vpc\", which is what infra-base/vpc creates and exports as its vpc_name output."
  type        = string
  default     = ""
}

variable "subnet_tag_type" {
  description = "Value of the tag:Type used to select the subnets the broker is placed in. \"database\" keeps it aligned with the other three midaz datastores; the pre-v2 stack used \"private\"."
  type        = string
  default     = "database"
}

################################################################################
# Ingress
#
# Same two-source model as products/shared-resources/rabbitmq, for the same reason: the
# midaz workloads run on the EKS nodes, and the broker has to be reachable from
# them on the first apply, before anyone has wired a security group by hand.
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
  description = "Allow the CIDR blocks of the Type=private subnets to reach the broker. This is the DEFAULT ingress path and the reason this stack can be applied before infra-base/eks exists. It is strictly tighter than the VPC-CIDR fallback the module ships, which additionally covers the public subnets."
  type        = bool
  default     = true
}

variable "eks_node_security_group_lookup_enabled" {
  description = "Resolve the EKS node security group by tag and allow it on the broker. Safe to leave true before infra-base/eks exists: the lookup uses data \"aws_security_groups\" (PLURAL), which returns an empty list rather than failing the plan."
  type        = bool
  default     = true
}

variable "eks_cluster_name" {
  description = "Name of the EKS cluster whose node security group is resolved. Leave empty (the default) to DERIVE \"lerian-{environment}-eks\" — the cluster belongs to infra-base and carries the \"lerian\" product label, NOT \"midaz\". The lookup matches by tag:Name = \"{cluster}-node\"."
  type        = string
  default     = ""
}

variable "allow_vpc_cidr_ingress" {
  description = "Passed straight to the module as its allow_vpc_cidr_ingress input. FALLBACK ONLY: applied exclusively when both allowed_cidr_blocks and allowed_security_group_ids resolve empty; any entry in either list wins outright and the VPC CIDR is never added on top."
  type        = bool
  default     = false
}

################################################################################
# Ports
################################################################################

variable "port" {
  description = "AMQPS port the broker listens on. AmazonMQ for RabbitMQ exposes NO plaintext AMQP listener, so this is 5671 and there is no reason to change it. Emitted as RABBITMQ_PORT_HOST — the chart's confusingly named AMQP port variable."
  type        = number
  default     = 5671
}

variable "console_port" {
  description = "Port of the RabbitMQ management console and management HTTP API. AmazonMQ serves both over HTTPS on 443. Emitted as RABBITMQ_PORT_AMQP — the chart's equally confusingly named management port variable."
  type        = number
  default     = 443
}

variable "enable_console_ingress" {
  description = "Also open console_port (443) to the resolved ingress sources, so the management console and the management HTTP API stay reachable from inside the VPC. The ledger's RABBITMQ_HEALTH_CHECK_URL targets exactly that API, so turning this off breaks the chart's broker health check as well as the console."
  type        = bool
  default     = true
}

################################################################################
# Broker engine and topology
################################################################################

# Renamed from `deployment_mode` in the module so it can never be confused with
# `var.mode` above. This is the AWS AmazonMQ topology knob.
variable "broker_deployment_mode" {
  description = "AmazonMQ topology: SINGLE_INSTANCE or CLUSTER_MULTI_AZ. Unrelated to var.mode. The topology does NOT constrain host_instance_type: every RabbitMQ instance type supports both. CLUSTER_MULTI_AZ costs three broker nodes instead of one."
  type        = string
  default     = "SINGLE_INSTANCE"

  validation {
    condition     = contains(["SINGLE_INSTANCE", "CLUSTER_MULTI_AZ"], var.broker_deployment_mode)
    error_message = "The broker_deployment_mode must be either 'SINGLE_INSTANCE' or 'CLUSTER_MULTI_AZ'. ACTIVE_STANDBY_MULTI_AZ is ActiveMQ only."
  }
}

variable "append_deployment_suffix" {
  description = "Append -single / -cluster to the broker name. Keep it true: it is what allows a side-by-side SINGLE_INSTANCE -> CLUSTER_MULTI_AZ migration (the two brokers coexist). The secret and the security group never carry the suffix; the broker does, which is why a shared consumer has to declare it — see shared_broker_name."
  type        = bool
  default     = true
}

variable "engine_version" {
  description = "RabbitMQ engine version."
  type        = string
  default     = "3.13"
}

variable "host_instance_type" {
  description = "Broker instance type. The RabbitMQ engine only accepts the mq.m5.* and mq.m7g.* families, and accepts all of them in BOTH deployment modes; mq.t2.* / mq.t3.* are ActiveMQ-only and fail CreateBroker. mq.m7g.medium is the smallest RabbitMQ type there is, which is why it is the default. The module enforces this at plan time."
  type        = string
  default     = "mq.m7g.medium"
}

variable "mq_admin_user" {
  description = "Administrator username of the broker. Feeds RABBITMQ_DEFAULT_USER / RABBITMQ_CONSUMER_USER unless separate users are created on the broker outside Terraform. Deliberately NOT marked sensitive at this level: the module marks its own copy sensitive, and reading it back through that output would redact the whole helm_values map. In mode = \"shared\" this is therefore the value the CALLER declares, not a read of the shared broker — keep it equal to the shared tier's admin user (both default to \"rabbitmqadmin\")."
  type        = string
  default     = "rabbitmqadmin"
}

variable "auto_minor_version_upgrade" {
  description = "Let AmazonMQ apply minor engine upgrades automatically."
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

################################################################################
# Helm handoff
################################################################################

