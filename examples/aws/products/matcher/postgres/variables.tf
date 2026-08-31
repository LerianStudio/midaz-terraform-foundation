################################################################################
# Stack identity
################################################################################

variable "region" {
  description = "AWS region the instance is created in. Must be the region the infra-base VPC lives in."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", var.region))
    error_message = "The region must be a valid AWS region identifier, e.g. us-east-1 or sa-east-1."
  }
}

variable "product" {
  description = "Product this instance belongs to. Pinned to \"matcher\" by validation: the derived name (matcher-{env}-postgres) and the derived secret path (matcher-{env}-postgres/password) ARE the cross-stack discovery contract. A different value here silently produces resources the matcher Helm release cannot find, with no error. A second product gets its own directory under examples/aws/products, not a different value here."
  type        = string
  default     = "matcher"

  validation {
    condition     = var.product == "matcher"
    error_message = "The product must be \"matcher\". This root stack is the matcher postgres datastore; every name and secret path it produces is derived from it. To provision postgres for another product, copy this directory to examples/aws/products/<product>/postgres instead."
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
  description = "\"dedicated\" creates a PostgreSQL instance owned by matcher (matcher-{env}-postgres). \"shared\" creates nothing and resolves the instance owned by products/shared-resources/postgres, looked up by name: shared-{env}-postgres plus the secret shared-{env}-postgres/password. In shared mode this stack resolves no VPC, no subnets and no EKS security group, and plans to zero resources."
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
# "lerian" product label — not "matcher", and not "shared" either (that one
# labels the shared DATASTORE tier in products/shared-resources). Deriving them
# from module.naming here would produce matcher-{env}-vpc /
# matcher-{env}-eks, which do not exist — which is why this root stack does
# not call the naming module at all.
################################################################################

variable "vpc_name" {
  description = "tag:Name of the VPC the instance is placed in. Leave empty (the default) to DERIVE \"lerian-{environment}-vpc\", which is what infra-base/vpc creates and exports as its vpc_name output."
  type        = string
  default     = ""
}

variable "subnet_tag_type" {
  description = "Value of the tag:Type used to select the subnets for the DB subnet group. infra-base/vpc tags its three database subnets with Type=database, which is the lookup contract."
  type        = string
  default     = "database"
}

################################################################################
# Ingress
#
# Same two-source model as products/shared-resources/postgres, for the same
# reason: the matcher workloads run on the EKS nodes, and the instance has to be
# reachable from them on the first apply, before anyone has wired a security
# group by hand.
#
#   1. allow_private_subnet_cidr_ingress (default true) — the CIDRs of the
#      Type=private subnets, resolved from the VPC. Works from the first apply
#      and needs nothing but infra-base/vpc.
#
#   2. the EKS node security group, resolved by tag when the cluster exists.
#      Empty (and harmless) before that: the lookup uses the PLURAL data source.
#
# Plus allowed_security_group_ids / allowed_cidr_blocks for anything else.
################################################################################

variable "allowed_security_group_ids" {
  description = "Extra security group IDs allowed to reach the instance. Merged with the EKS node security group when eks_node_security_group_lookup_enabled is true."
  type        = list(string)
  default     = []
}

variable "allowed_cidr_blocks" {
  description = "Extra CIDR blocks allowed to reach the instance. Merged with the private subnet CIDRs when allow_private_subnet_cidr_ingress is true."
  type        = list(string)
  default     = []
}

variable "allow_private_subnet_cidr_ingress" {
  description = "Allow the CIDR blocks of the Type=private subnets to reach the instance. This is the DEFAULT ingress path and the reason this stack can be applied before infra-base/eks exists. It is strictly tighter than the VPC-CIDR fallback the module ships, which additionally covers the public subnets. Set it to false once the EKS node security group is being resolved, to move to security-group-only ingress."
  type        = bool
  default     = true
}

variable "eks_node_security_group_lookup_enabled" {
  description = "Resolve the EKS node security group by tag and allow it on the instance. Safe to leave true before infra-base/eks exists: the lookup uses data \"aws_security_groups\" (PLURAL), which returns an empty list rather than failing the plan, so this stack stays appliable and starts producing the rule on the first apply after the cluster exists."
  type        = bool
  default     = true
}

variable "eks_cluster_name" {
  description = "Name of the EKS cluster whose node security group is resolved. Leave empty (the default) to DERIVE \"lerian-{environment}-eks\" — the cluster belongs to infra-base and carries the \"lerian\" product label, NOT \"matcher\". The lookup matches the node security group by tag:Name = \"{cluster}-node\", which is what terraform-aws-modules/eks sets."
  type        = string
  default     = ""
}

variable "allow_vpc_cidr_ingress" {
  description = "Passed straight to the module as its allow_vpc_cidr_ingress input. FALLBACK ONLY: the module applies it exclusively when both allowed_cidr_blocks and allowed_security_group_ids resolve empty; any entry in either list wins outright and the VPC CIDR is never added on top. Kept false here because this stack computes its allow lists explicitly and would rather trip the module's check \"ingress_is_reachable\" than quietly widen to a CIDR that includes the public subnets."
  type        = bool
  default     = false
}

################################################################################
# Engine
################################################################################

variable "engine_version" {
  description = "PostgreSQL engine version. Keep it MAJOR-only (\"16\"): RDS then picks the latest available minor and the provider treats the config as a prefix, so there is no perpetual diff. Pinning a full minor is a maintenance trap — AWS retired 16.3 and every apply that pinned it started failing with \"Cannot find version 16.3 for postgres\"."
  type        = string
  default     = "16"
}

variable "family" {
  description = "PostgreSQL parameter group family, e.g. postgres16. Must agree with engine_version."
  type        = string
  default     = "postgres16"
}

variable "major_engine_version" {
  description = "PostgreSQL major engine version, e.g. 16. Must agree with engine_version."
  type        = string
  default     = "16"
}

variable "database_name" {
  description = "Name of the initial database created on the instance. NOT read from a chart — there is no readable Matcher chart in this repository, so no application default is known. Naming the initial database after the product is an infrastructure choice that claims nothing about the application's configuration; the value is published as the database_name output so the release can be pointed at it explicitly. Reconcile it with the chart when the chart exists."
  type        = string
  default     = "matcher"
}

variable "username" {
  description = "Master username of the instance. Deliberately the generic RDS default rather than something product-shaped: with no chart to read, any application-looking username would be a guess dressed up as a contract. The value is published as the username output; give the application its own least-privilege role once the chart defines one."
  type        = string
  default     = "postgres"
}

################################################################################
# Sizing and storage
################################################################################

variable "instance_class" {
  description = "Instance class. db.t4g.micro is the cheapest class RDS offers for PostgreSQL and is the intended dev value; it does NOT support Performance Insights."
  type        = string
  default     = "db.t4g.micro"
}

variable "allocated_storage" {
  description = "Allocated storage in GB."
  type        = number
  default     = 20
}

variable "max_allocated_storage" {
  description = "Storage autoscaling ceiling in GB."
  type        = number
  default     = 100
}

variable "multi_az" {
  description = "Deploy the instance across two availability zones. Roughly doubles the instance cost."
  type        = bool
  default     = false
}

################################################################################
# Read replica
################################################################################

variable "create_read_replica" {
  description = "Create a read replica, matcher-{env}-postgres-replica, published as the replica_endpoint output. Whether the Matcher application can use one is unknown — the chart is not in this repository — so this defaults to false in every environment, including prd. Turn it on only after confirming the application has a read path."
  type        = bool
  default     = false
}

variable "read_replica_instance_class" {
  description = "Instance class of the read replica. The module passes it straight through, so set it whenever create_read_replica is true."
  type        = string
  default     = null
}

variable "read_replica_multi_az" {
  description = "Deploy the read replica across two availability zones."
  type        = bool
  default     = false
}

################################################################################
# Maintenance and backup
################################################################################

variable "backup_retention_period" {
  description = "Automated backup retention in days."
  type        = number
  default     = 7
}

variable "skip_final_snapshot" {
  description = "Skip the final snapshot when the instance is destroyed. true in dev, false in prd."
  type        = bool
  default     = false
}

variable "deletion_protection" {
  description = "Protect the instance from deletion. false in dev, true in prd."
  type        = bool
  default     = true
}

################################################################################
# Monitoring
################################################################################

variable "monitoring_interval" {
  description = "Enhanced Monitoring interval in seconds. 0 disables it, which also makes the monitoring IAM role unnecessary."
  type        = number
  default     = 0

  validation {
    condition     = contains([0, 1, 5, 10, 15, 30, 60], var.monitoring_interval)
    error_message = "The monitoring_interval must be one of: 0, 1, 5, 10, 15, 30, 60."
  }
}

variable "create_monitoring_role" {
  description = "Create the RDS Enhanced Monitoring IAM role. Keep it aligned with monitoring_interval: a role with no monitoring is dead weight, monitoring with no role fails the apply."
  type        = bool
  default     = false
}

variable "performance_insights_enabled" {
  description = "Enable Performance Insights. AWS does NOT offer it on db.t2/t3/t4g micro and small, and the module rejects that combination with a plan-time precondition — so this MUST be false on the db.t4g.micro dev sizing."
  type        = bool
  default     = false
}

variable "performance_insights_retention_period" {
  description = "Days of Performance Insights data retained. Valid values are 7, 731, or a multiple of 31."
  type        = number
  default     = 7
}

variable "enabled_cloudwatch_logs_exports" {
  description = "PostgreSQL log types exported to CloudWatch Logs. An empty list also skips the log groups."
  type        = list(string)
  default     = ["postgresql", "upgrade"]
}

variable "parameters" {
  description = "DB parameters applied to the parameter group, as a list of {name, value} (and optionally apply_method for a static parameter that needs a reboot). THIS IS WHERE TLS IS ENFORCED: rds.force_ssl = \"1\" makes the server REFUSE any non-TLS connection, and it is the only place in this repository that can state it — the module ships an empty parameter list and RDS defaults force_ssl to 0 on the postgres families, so a database with no entry here accepts plaintext from anything inside the security group. Encryption in transit is a client policy decision everywhere else in this repo; on a money path it is not."
  type = list(object({
    name         = string
    value        = string
    apply_method = optional(string)
  }))
  default = []
}
