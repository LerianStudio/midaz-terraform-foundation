################################################################################
# Contract variables (identical across every Lerian datastore module)
################################################################################

variable "product" {
  description = "Lerian product this cluster belongs to (e.g. midaz, br-sfn, br-sisbajud). Use \"shared\" for the tier owned by products/shared-resources/msk — NOT \"lerian\", which labels the foundation (lerian-{env}-vpc, lerian-{env}-eks)."
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

variable "mode" {
  description = "\"dedicated\" provisions an MSK cluster for this product. \"shared\" creates nothing and resolves the infra-base cluster shared-{environment}-msk instead."
  type        = string
  default     = "dedicated"

  validation {
    condition     = contains(["dedicated", "shared"], var.mode)
    error_message = "The mode must be one of: dedicated, shared."
  }
}

variable "vpc_name" {
  description = "tag:Name of the VPC hosting the brokers. Empty derives \"lerian-{environment}-vpc\"."
  type        = string
  default     = ""
}

variable "subnet_tag_type" {
  description = "Value of the Type tag used to select the broker subnets. The vpc stack tags its subnets with this key."
  type        = string
  default     = "database"
}

variable "egress_cidr_blocks" {
  description = "Destination CIDRs the broker security group may send traffic to. Defaults to 0.0.0.0/0, which is the effective posture of every datastore in this repository (Terraform preserves the allow-all egress rule AWS attaches to a new security group). Narrow it to the VPC CIDR when broker egress to AWS public endpoints is not required. An empty list creates no egress rule at all, which relies on nothing outbound being needed."
  type        = list(string)
  default     = ["0.0.0.0/0"]

  validation {
    condition     = alltrue([for c in var.egress_cidr_blocks : can(cidrnetmask(c))])
    error_message = "Every entry in egress_cidr_blocks must be a valid IPv4 CIDR block."
  }
}

variable "subnet_ids" {
  description = "Escape hatch that overrides the subnet lookup. MSK accepts exactly 2 or 3 client subnets in distinct availability zones, so set this when the VPC tags more subnets than that with subnet_tag_type."
  type        = list(string)
  default     = []
}

variable "shared_secret_name" {
  description = "Escape hatch for mode = \"shared\": overrides the Secrets Manager secret name resolved for the shared cluster's SASL/SCRAM credentials. Use it when the secret was created outside this Terraform. Defaults to \"AmazonMSK_shared-{environment}-msk\". AWS REQUIRES the AmazonMSK_ prefix on any secret associated with an MSK cluster, so an override without it is rejected at plan time."
  type        = string
  default     = ""

  validation {
    condition     = var.shared_secret_name == "" || startswith(var.shared_secret_name, "AmazonMSK_")
    error_message = "The shared_secret_name must start with \"AmazonMSK_\". AWS rejects any other name on a secret associated with an MSK cluster (aws_msk_scram_secret_association), so a secret without the prefix cannot be the one holding the shared cluster's SASL/SCRAM credentials. Leave it empty to derive \"AmazonMSK_shared-{environment}-msk\"."
  }
}

################################################################################
# Ingress
#
# The three variables below implement ONE rule, worded identically in all five
# Lerian datastore modules. Do not diverge them.
################################################################################

variable "allowed_security_group_ids" {
  description = "Security group IDs allowed to reach the datastore port. Any entry here or in allowed_cidr_blocks disables the VPC CIDR fallback: only what is listed is allowed, and nothing is added on top. When both lists are empty the fallback in allow_vpc_cidr_ingress decides. Rules are opened only on the listener ports the selected authentication modes enable."
  type        = list(string)
  default     = []
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed to reach the datastore port. Any entry here or in allowed_security_group_ids disables the VPC CIDR fallback: only what is listed is allowed, and nothing is added on top. When both lists are empty the fallback in allow_vpc_cidr_ingress decides. Rules are opened only on the listener ports the selected authentication modes enable."
  type        = list(string)
  default     = []
}

variable "allow_vpc_cidr_ingress" {
  description = "FALLBACK ONLY. Allow the whole VPC CIDR to reach the datastore port when allowed_cidr_blocks and allowed_security_group_ids are BOTH empty - the pre-refactor behaviour, kept so a migrated stack does not silently lose connectivity. It is never applied on top of a non-empty allow list. Set false to make empty allow lists mean no ingress at all; a check block then warns that the datastore is unreachable."
  type        = bool
  default     = true
}

################################################################################
# Cluster sizing and engine
################################################################################

variable "kafka_version" {
  description = "Apache Kafka version to run on the brokers."
  type        = string
  default     = "3.6.0"
}

variable "number_of_broker_nodes" {
  description = "Total number of broker nodes. MSK requires a multiple of the number of client subnets, which is enforced by a precondition."
  type        = number
  default     = 3

  validation {
    condition     = var.number_of_broker_nodes >= 2
    error_message = "The number_of_broker_nodes must be at least 2, since MSK spreads brokers across at least two availability zones."
  }
}

variable "broker_instance_type" {
  description = "Broker instance type. kafka.t3.small is the smallest MSK offers and is the intended dev size."
  type        = string
  default     = "kafka.t3.small"
}

variable "broker_ebs_volume_size" {
  description = "EBS volume size in GiB attached to each broker."
  type        = number
  default     = 100

  validation {
    condition     = var.broker_ebs_volume_size >= 1 && var.broker_ebs_volume_size <= 16384
    error_message = "The broker_ebs_volume_size must be between 1 and 16384 GiB."
  }
}

variable "enable_storage_autoscaling" {
  description = "Whether Application Auto Scaling grows broker storage when utilisation crosses storage_autoscaling_target_percent."
  type        = bool
  default     = false
}

variable "storage_autoscaling_max_capacity" {
  description = "Upper bound in GiB for broker storage autoscaling."
  type        = number
  default     = 250
}

variable "storage_autoscaling_target_percent" {
  description = "Broker storage utilisation percentage that triggers autoscaling."
  type        = number
  default     = 70
}

variable "storage_mode" {
  description = "Broker storage tier. Empty leaves the AWS default. TIERED is not supported by the kafka.t3.* family."
  type        = string
  default     = ""

  validation {
    condition     = contains(["", "LOCAL", "TIERED"], var.storage_mode)
    error_message = "The storage_mode must be one of: \"\" (AWS default), LOCAL, TIERED."
  }
}

variable "enhanced_monitoring" {
  description = "CloudWatch monitoring level for the cluster."
  type        = string
  default     = "DEFAULT"

  validation {
    condition = contains([
      "DEFAULT",
      "PER_BROKER",
      "PER_TOPIC_PER_BROKER",
      "PER_TOPIC_PER_PARTITION",
    ], var.enhanced_monitoring)
    error_message = "The enhanced_monitoring must be one of: DEFAULT, PER_BROKER, PER_TOPIC_PER_BROKER, PER_TOPIC_PER_PARTITION."
  }
}

################################################################################
# Encryption
################################################################################

variable "encryption_in_transit_client_broker" {
  description = "Encryption between clients and brokers. TLS is the default and is mandatory when SASL/SCRAM is enabled."
  type        = string
  default     = "TLS"

  validation {
    condition     = contains(["TLS", "TLS_PLAINTEXT", "PLAINTEXT"], var.encryption_in_transit_client_broker)
    error_message = "The encryption_in_transit_client_broker must be one of: TLS, TLS_PLAINTEXT, PLAINTEXT."
  }
}

variable "encryption_at_rest_kms_key_arn" {
  description = "ARN of an existing KMS CMK for data at rest. Empty makes the module create a dedicated CMK with rotation enabled."
  type        = string
  default     = ""
}

variable "kms_deletion_window_in_days" {
  description = "Waiting period before a CMK created by this module is destroyed."
  type        = number
  default     = 10

  validation {
    condition     = var.kms_deletion_window_in_days >= 7 && var.kms_deletion_window_in_days <= 30
    error_message = "The kms_deletion_window_in_days must be between 7 and 30."
  }
}

################################################################################
# Client authentication
################################################################################

variable "enable_sasl_scram" {
  description = "Enable SASL/SCRAM authentication. The module then provisions the credentials in Secrets Manager under a customer managed CMK, which is what MSK requires."
  type        = bool
  default     = true
}

variable "scram_username" {
  description = "SASL/SCRAM username stored in Secrets Manager."
  type        = string
  default     = "lerian"
}

variable "enable_tls_client_auth" {
  description = "Enable mutual TLS client authentication. Requires tls_certificate_authority_arns."
  type        = bool
  default     = false
}

variable "tls_certificate_authority_arns" {
  description = "ACM Private CA ARNs that sign the client certificates when enable_tls_client_auth is true."
  type        = list(string)
  default     = []
}

variable "enable_unauthenticated" {
  description = "Allow unauthenticated access. Intended for throwaway environments only."
  type        = bool
  default     = false
}

################################################################################
# Cluster configuration (server.properties)
################################################################################

variable "create_configuration" {
  description = "Whether to create an aws_msk_configuration and attach it to the cluster."
  type        = bool
  default     = true
}

variable "auto_create_topics_enable" {
  description = "Kafka auto.create.topics.enable. Kept false because the Lerian charts create their topics explicitly through a PreSync rpk job."
  type        = bool
  default     = false
}

variable "default_replication_factor" {
  description = "Kafka default.replication.factor. Null derives min(number_of_broker_nodes, 3) so a single-AZ dev cluster stays valid."
  type        = number
  default     = null
}

variable "extra_server_properties" {
  description = "Additional server.properties entries merged on top of the ones this module manages."
  type        = map(string)
  default     = {}
}

################################################################################
# Logging
################################################################################

variable "cloudwatch_logs_enabled" {
  description = "Stream broker logs to CloudWatch Logs. The log group is named from the naming module."
  type        = bool
  default     = false
}

variable "cloudwatch_log_group_retention_in_days" {
  description = "Retention of the broker log group. 0 keeps logs forever."
  type        = number
  default     = 7
}

variable "cloudwatch_log_group_kms_key_arn" {
  description = "KMS CMK encrypting the broker log group. Empty uses the CloudWatch Logs default key. A CMK passed here must allow logs.{region}.amazonaws.com in its key policy."
  type        = string
  default     = ""
}

variable "prometheus_jmx_exporter_enabled" {
  description = "Expose the Prometheus JMX exporter on the brokers."
  type        = bool
  default     = false
}

variable "prometheus_node_exporter_enabled" {
  description = "Expose the Prometheus node exporter on the brokers."
  type        = bool
  default     = false
}

################################################################################
# Tagging
################################################################################

variable "extra_tags" {
  description = "Additional tags merged on top of the standard Lerian tag set."
  type        = map(string)
  default     = {}
}
