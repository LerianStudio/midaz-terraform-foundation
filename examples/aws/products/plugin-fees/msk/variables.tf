################################################################################
# Stack identity
#
# Unlike products/shared-resources/msk — which is the OWNER of the shared tier
# and therefore pins its module to mode = "dedicated" — this is a PRODUCT root
# and exposes var.mode. Read the header of main.tf before choosing a value: the
# default is "dedicated" for uniformity with every other product root, but
# "shared" is the intended value for plugin-fees.
################################################################################

variable "region" {
  description = "AWS region the cluster is created in or resolved from. Must be the region the infra-base VPC lives in."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", var.region))
    error_message = "The region must be a valid AWS region identifier, e.g. us-east-1 or sa-east-1."
  }
}

variable "product" {
  description = "Product this datastore belongs to. Pinned to \"plugin-fees\" by validation: in dedicated mode the derived name (plugin-fees-{env}-msk) and the derived secret name (AmazonMSK_plugin-fees-{env}-msk) ARE the cross-stack discovery contract. Note the directory and the label keep the chart's own \"plugin-\" prefix. In SHARED mode this value does not select the cluster — the module derives shared-{env}-msk from the \"shared\" literal, not from this label."
  type        = string
  default     = "plugin-fees"

  validation {
    condition     = var.product == "plugin-fees"
    error_message = "The product must be \"plugin-fees\". This root stack is the plugin-fees Kafka datastore; every name and secret path it produces in dedicated mode is derived from it. To provision MSK for another product, copy this directory to examples/aws/products/<product>/msk instead."
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

variable "mode" {
  description = "\"dedicated\" creates an MSK cluster owned by plugin-fees (plugin-fees-{env}-msk) — three brokers minimum, roughly USD 105/month, for a feature the chart ships turned off. \"shared\" creates nothing and resolves the cluster owned by products/shared-resources/msk, looked up by name: shared-{env}-msk plus the secret AmazonMSK_shared-{env}-msk. SHARED IS THE INTENDED VALUE FOR THIS PRODUCT and is what every tfvars-example in envs/ sets; the default stays \"dedicated\" only so this root behaves like every other product root. In shared mode this stack resolves no VPC, no subnets and no EKS security group, plans to zero resources, and gets security_group_id = null — authorising plugin-fees on the shared cluster is products/shared-resources/msk's job."
  type        = string
  default     = "dedicated"

  validation {
    condition     = contains(["dedicated", "shared"], var.mode)
    error_message = "The mode must be one of: dedicated, shared."
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
# "lerian" product label — not "plugin-fees", and not "shared" either.
################################################################################

variable "vpc_name" {
  description = "tag:Name of the VPC the brokers are placed in. Leave empty (the default) to DERIVE \"lerian-{environment}-vpc\", which is what infra-base/vpc creates and exports as its vpc_name output. Ignored in shared mode."
  type        = string
  default     = ""
}

variable "subnet_tag_type" {
  description = "Value of the tag:Type used to select the CLIENT SUBNETS the brokers are placed in. infra-base/vpc tags its three database subnets with Type=database, which is the lookup contract. MSK accepts exactly 2 or 3 client subnets in distinct availability zones — see subnet_ids to narrow the set."
  type        = string
  default     = "database"
}

variable "subnet_ids" {
  description = "Escape hatch overriding the MSK subnet lookup. MSK accepts EXACTLY 2 or 3 client subnets in distinct availability zones, and number_of_broker_nodes must be a MULTIPLE of however many are used. Set this to force a 2-broker cluster in dev — which cannot be written into a tfvars-example because the subnet ids are generated."
  type        = list(string)
  default     = []
}

################################################################################
# Ingress
################################################################################

variable "allowed_security_group_ids" {
  description = "Extra security group IDs allowed to reach the brokers on their client ports. Merged with the EKS node security group when eks_node_security_group_lookup_enabled is true. Ignored in shared mode, where this stack creates no security group at all."
  type        = list(string)
  default     = []
}

variable "allowed_cidr_blocks" {
  description = "Extra CIDR blocks allowed to reach the brokers on their client ports. Merged with the private subnet CIDRs when allow_private_subnet_cidr_ingress is true. Ignored in shared mode."
  type        = list(string)
  default     = []
}

variable "allow_private_subnet_cidr_ingress" {
  description = "Allow the CIDR blocks of the Type=private subnets to reach the brokers. This is the DEFAULT ingress path and the reason this stack can be applied before infra-base/eks exists. It matters more on MSK than anywhere else: the module used to ship no VPC-CIDR fallback at all, so empty allow lists produced a cluster with zero ingress that looked healthy and accepted no connections."
  type        = bool
  default     = true
}

variable "eks_node_security_group_lookup_enabled" {
  description = "Resolve the EKS node security group by tag and allow it on the brokers. Safe to leave true before infra-base/eks exists: the lookup uses data \"aws_security_groups\" (PLURAL), which returns an empty list rather than failing the plan."
  type        = bool
  default     = true
}

variable "eks_cluster_name" {
  description = "Name of the EKS cluster whose node security group is resolved. Leave empty (the default) to DERIVE \"lerian-{environment}-eks\" — the cluster belongs to infra-base and carries the \"lerian\" product label. The lookup matches by tag:Name = \"{cluster}-node\"."
  type        = string
  default     = ""
}

variable "allow_vpc_cidr_ingress" {
  description = "Passed straight to the module as its allow_vpc_cidr_ingress input. FALLBACK ONLY: applied exclusively when both allowed_cidr_blocks and allowed_security_group_ids resolve empty; any entry in either list wins outright and the VPC CIDR is never added on top. Kept false so an empty allow list trips the module's check \"ingress_is_reachable\" instead of quietly widening to a CIDR that includes the public subnets."
  type        = bool
  default     = false
}

################################################################################
# Cluster sizing — all of it IGNORED in shared mode
#
# THE BROKER COUNT IS THE COST, and it is not negotiable downward. AWS requires
# number_of_broker_nodes to be a MULTIPLE of the number of client subnets, and
# the module asserts it at plan time. With the three Type=database subnets
# infra-base/vpc creates, the valid values are 3, 6, 9 — three brokers is the
# floor, roughly USD 105/month on kafka.t3.small. Narrowing subnet_ids to two
# subnets is the only way to a 2-broker cluster.
################################################################################

variable "kafka_version" {
  description = "Apache Kafka version of the cluster."
  type        = string
  default     = "3.6.0"
}

variable "number_of_broker_nodes" {
  description = "Total broker nodes. MUST be a multiple of the number of client subnets, which the module asserts at plan time: with the three Type=database subnets infra-base/vpc creates, the valid values are 3, 6, 9. Use subnet_ids to narrow the subnet set if you need 2."
  type        = number
  default     = 3
}

variable "broker_instance_type" {
  description = "Broker instance type. kafka.t3.small is the smallest MSK offers and is the intended dev value."
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
  description = "Client-to-broker encryption. TLS is mandatory when SASL/SCRAM is enabled, and it is what makes the chart's STREAMING_TLS_ENABLED = \"true\" correct."
  type        = string
  default     = "TLS"

  validation {
    condition     = contains(["TLS", "TLS_PLAINTEXT", "PLAINTEXT"], var.encryption_in_transit_client_broker)
    error_message = "The encryption_in_transit_client_broker must be one of: TLS, TLS_PLAINTEXT, PLAINTEXT."
  }
}

variable "enable_sasl_scram" {
  description = "Enable SASL/SCRAM authentication. In dedicated mode the credentials land in Secrets Manager as AmazonMSK_plugin-fees-{environment}-msk under a customer managed CMK — the AmazonMSK_ prefix and the CMK are both AWS requirements for a secret associated with a cluster. MSK implements SCRAM-SHA-512 only, which is what the chart's STREAMING_SASL_MECHANISM has to be set to."
  type        = bool
  default     = true
}

variable "scram_username" {
  description = "SASL/SCRAM username stored in Secrets Manager, emitted as the chart's STREAMING_SASL_USERNAME. Not a resource name, so it does not carry the product prefix. The module creates ONE user; per-topic ACLs are created against the cluster itself, outside Terraform. In shared mode this must match the username products/shared-resources/msk created (default \"lerian\" on both sides) — the module reads the shared secret, but the username is declared here."
  type        = string
  default     = "lerian"
}

variable "enable_unauthenticated" {
  description = "Allow unauthenticated Kafka access. Throwaway environments only."
  type        = bool
  default     = false
}

################################################################################
# Kafka configuration
################################################################################

variable "auto_create_topics_enable" {
  description = "Kafka auto.create.topics.enable. Keep it false: the Lerian charts create their topics explicitly from an ArgoCD PreSync rpk job, which keeps the topic set versioned with the service that owns it."
  type        = bool
  default     = false
}

variable "default_replication_factor" {
  description = "Kafka default.replication.factor. Null derives min(number_of_broker_nodes, 3)."
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
  description = "CloudWatch monitoring level: DEFAULT, PER_BROKER, PER_TOPIC_PER_BROKER or PER_TOPIC_PER_PARTITION. Per-topic levels cost more."
  type        = string
  default     = "DEFAULT"
}

variable "cloudwatch_logs_enabled" {
  description = "Stream broker logs to CloudWatch Logs."
  type        = bool
  default     = false
}

variable "cloudwatch_log_group_retention_in_days" {
  description = "Retention of the broker log group. 0 keeps logs forever."
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

################################################################################
# Helm handoff extras
################################################################################

variable "streaming_sasl_mechanism" {
  description = "Value emitted as the chart's STREAMING_SASL_MECHANISM. LEFT EMPTY ON PURPOSE, and empty omits the key entirely. The AWS half is settled — MSK implements SCRAM-SHA-512 and nothing else — but the SPELLING the Lerian streaming client accepts is not verifiable from the chart: templates/fees/configmap.yaml:123 renders the value with an empty default and no template, values file or schema in plugin-fees-helm 7.3.0 enumerates the accepted strings. Emitting a guess (\"SCRAM-SHA-512\" vs \"scram-sha-512\" vs \"SCRAM_SHA_512\") would produce a release that fails to authenticate for a reason nobody would look for here. CONFIRMAR against lib-streaming, then set this once and the whole handoff is complete."
  type        = string
  default     = ""
}

variable "streaming_cloudevents_source" {
  description = "Value emitted as the chart's STREAMING_CLOUDEVENTS_SOURCE. Not an AWS setting — it is the CloudEvents `source` attribute the fee engine stamps on every event — but it belongs in helm_values so the streaming wiring is complete in one place. The chart default is \"lerian.midaz.fees\"; leave it empty to omit the key and keep that default."
  type        = string
  default     = ""
}
