################################################################################
# Stack identity
#
# There is no `mode` variable in this root, deliberately. The module call is
# pinned to mode = "dedicated" because this stack is the OWNER of the shared
# cluster — see the header of main.tf.
#
# There is no `msk_enabled` toggle either. Enabling this datastore is applying
# this directory.
################################################################################

variable "region" {
  description = "AWS region the shared cluster is created in. Must be the region the infra-base VPC lives in."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", var.region))
    error_message = "The region must be a valid AWS region identifier, e.g. us-east-1 or sa-east-1."
  }
}

variable "product" {
  description = "Product label this cluster carries. Keep the default \"shared\": that is what makes the derived name (shared-{env}-msk) and the derived secret name (AmazonMSK_shared-{env}-msk) match exactly what streaming-msk looks up when a product sets mode = \"shared\". Changing it makes every shared consumer unresolvable. The FOUNDATION stacks keep the \"lerian\" label (lerian-{env}-vpc, lerian-{env}-eks) because they have no dedicated counterpart; this DATASTORE tier carries \"shared\"."
  type        = string
  default     = "shared"

  validation {
    condition     = var.product == "shared"
    error_message = "The product must be \"shared\". The shared mode of streaming-msk derives the cluster name as \"shared-{environment}-msk\" and the secret as \"AmazonMSK_shared-{environment}-msk\". A different product here produces a cluster no shared consumer can find. If you genuinely want a second cluster, that is a product root stack with mode = \"dedicated\", not this one."
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
  description = "tag:Name of the VPC the brokers are placed in. Leave empty (the default) to DERIVE \"lerian-{environment}-vpc\", which is what infra-base/vpc creates and exports as its vpc_name output."
  type        = string
  default     = ""
}

variable "subnet_tag_type" {
  description = "Value of the tag:Type used to select the CLIENT SUBNETS the brokers are placed in. infra-base/vpc tags its three database subnets with Type=database, which is the lookup contract. MSK accepts exactly 2 or 3 client subnets in distinct availability zones — see subnet_ids to narrow the set."
  type        = string
  default     = "database"
}

variable "subnet_ids" {
  description = "Escape hatch overriding the MSK subnet lookup. MSK accepts EXACTLY 2 or 3 client subnets in distinct availability zones, and number_of_broker_nodes must be a MULTIPLE of however many are used. Set this when the VPC tags a different number with subnet_tag_type, or to force a 2-broker cluster in dev — which cannot be written into a tfvars-example because the subnet ids are generated."
  type        = list(string)
  default     = []
}

################################################################################
# Ingress — the part the shared model lives or dies on
#
# A product running with mode = "shared" gets security_group_id = null from its
# module: it creates no security group and therefore cannot authorise itself.
# Opening the shared cluster is exclusively this stack's job. This mattered most
# on MSK: the module used to ship NO VPC-CIDR fallback at all, so empty allow
# lists produced zero ingress and a silently unreachable cluster. It now carries
# check "ingress_is_reachable".
################################################################################

variable "allowed_security_group_ids" {
  description = "Extra security group IDs allowed to reach the brokers on their client ports. Merged with the EKS node security group when eks_node_security_group_lookup_enabled is true."
  type        = list(string)
  default     = []
}

variable "allowed_cidr_blocks" {
  description = "Extra CIDR blocks allowed to reach the brokers on their client ports. Merged with the private subnet CIDRs when allow_private_subnet_cidr_ingress is true."
  type        = list(string)
  default     = []
}

variable "allow_private_subnet_cidr_ingress" {
  description = "Allow the CIDR blocks of the Type=private subnets to reach the brokers. This is the DEFAULT ingress path and the reason this stack can be applied before infra-base/eks exists. It is strictly tighter than the VPC-CIDR fallback, which additionally covers the public subnets. Set it to false once the EKS node security group is being resolved, to move to security-group-only ingress."
  type        = bool
  default     = true
}

variable "eks_node_security_group_lookup_enabled" {
  description = "Resolve the EKS node security group by tag and allow it on the brokers. Safe to leave true before infra-base/eks exists: the lookup uses data \"aws_security_groups\" (PLURAL), which returns an empty list rather than failing the plan."
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
# Cluster sizing
#
# MSK HAS NO CHEAP CORNER, and the broker count is the reason. AWS requires
# number_of_broker_nodes to be a MULTIPLE of the number of client subnets, and
# the module asserts it at plan time. With the three Type=database subnets
# infra-base/vpc creates, the valid values are 3, 6, 9 — three brokers is the
# floor, roughly USD 105/month on kafka.t3.small. Narrowing subnet_ids to two
# subnets is the only way to a 2-broker cluster.
################################################################################

variable "kafka_version" {
  description = "Apache Kafka version of the shared cluster."
  type        = string
  default     = "3.6.0"
}

variable "number_of_broker_nodes" {
  description = "Total broker nodes in the shared cluster. MUST be a multiple of the number of client subnets, which the module asserts at plan time: with the three Type=database subnets infra-base/vpc creates, the valid values are 3, 6, 9. Use subnet_ids to narrow the subnet set if you need 2."
  type        = number
  default     = 3
}

variable "broker_instance_type" {
  description = "Broker instance type of the shared cluster. kafka.t3.small is the smallest MSK offers and is the intended dev value."
  type        = string
  default     = "kafka.t3.small"
}

variable "broker_ebs_volume_size" {
  description = "EBS volume size in GiB per broker."
  type        = number
  default     = 100
}

variable "storage_mode" {
  description = "Broker storage tier. Empty leaves the AWS default. TIERED moves cold segments off the broker EBS volume and is the lever to pull when retention grows — but it is REJECTED by the kafka.t3.* family, so it cannot be used on the dev sizing."
  type        = string
  default     = ""

  validation {
    condition     = contains(["", "LOCAL", "TIERED"], var.storage_mode)
    error_message = "The storage_mode must be one of: \"\" (AWS default), LOCAL, TIERED."
  }
}

variable "enable_storage_autoscaling" {
  description = "Let Application Auto Scaling grow broker storage."
  type        = bool
  default     = false
}

variable "storage_autoscaling_max_capacity" {
  description = "Upper bound in GiB for broker storage autoscaling."
  type        = number
  default     = 250
}

variable "storage_autoscaling_target_percent" {
  description = "Storage utilisation percentage Application Auto Scaling targets."
  type        = number
  default     = 70
}

################################################################################
# Security
################################################################################

variable "encryption_in_transit_client_broker" {
  description = "Client-to-broker encryption. TLS is mandatory when SASL/SCRAM is enabled."
  type        = string
  default     = "TLS"

  validation {
    condition     = contains(["TLS", "TLS_PLAINTEXT", "PLAINTEXT"], var.encryption_in_transit_client_broker)
    error_message = "The encryption_in_transit_client_broker must be one of: TLS, TLS_PLAINTEXT, PLAINTEXT."
  }
}

variable "enable_sasl_scram" {
  description = "Enable SASL/SCRAM authentication on the shared cluster. The credentials land in Secrets Manager as AmazonMSK_shared-{environment}-msk under a customer managed CMK — the AmazonMSK_ prefix and the CMK are both AWS requirements for a secret associated with a cluster — and that is exactly the name a shared consumer resolves."
  type        = bool
  default     = true
}

variable "scram_username" {
  description = "SASL/SCRAM username stored in Secrets Manager for the shared cluster. Not a resource name, which is why it stays \"lerian\" rather than \"shared\". The module creates ONE user; per-product users and ACLs are created against the cluster itself, outside Terraform."
  type        = string
  default     = "lerian"
}

variable "enable_unauthenticated" {
  description = "Allow unauthenticated Kafka access to the shared cluster. Throwaway environments only — on a shared cluster it removes the only boundary between consumers."
  type        = bool
  default     = false
}

################################################################################
# Kafka configuration
################################################################################

variable "auto_create_topics_enable" {
  description = "Kafka auto.create.topics.enable. Keep it false: the Lerian charts create their topics explicitly from an ArgoCD PreSync rpk job, which keeps the topic set versioned with the service that owns it. On a SHARED cluster that also keeps two products from silently colliding on a topic name."
  type        = bool
  default     = false
}

variable "default_replication_factor" {
  description = "Kafka default.replication.factor for the shared cluster. Null derives min(number_of_broker_nodes, 3)."
  type        = number
  default     = null
}

variable "extra_server_properties" {
  description = "Additional server.properties entries merged on top of the ones the module manages."
  type        = map(string)
  default     = {}
}

################################################################################
# Observability
################################################################################

variable "enhanced_monitoring" {
  description = "CloudWatch monitoring level of the shared cluster: DEFAULT, PER_BROKER, PER_TOPIC_PER_BROKER or PER_TOPIC_PER_PARTITION. Per-topic levels are what let you attribute load to a consuming product on a shared cluster, and they cost more."
  type        = string
  default     = "DEFAULT"
}

variable "cloudwatch_logs_enabled" {
  description = "Stream shared-cluster broker logs to CloudWatch Logs."
  type        = bool
  default     = false
}

variable "cloudwatch_log_group_retention_in_days" {
  description = "Retention of the shared-cluster broker log group. 0 keeps logs forever."
  type        = number
  default     = 7
}

variable "prometheus_jmx_exporter_enabled" {
  description = "Expose the broker JMX metrics for Prometheus scraping."
  type        = bool
  default     = false
}

variable "prometheus_node_exporter_enabled" {
  description = "Expose the broker node metrics for Prometheus scraping."
  type        = bool
  default     = false
}
