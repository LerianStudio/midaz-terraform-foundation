################################################################################
# Stack identity
################################################################################

variable "region" {
  description = "AWS region the replication group is created in. Must be the region the infra-base VPC lives in."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", var.region))
    error_message = "The region must be a valid AWS region identifier, e.g. us-east-1 or sa-east-1."
  }
}

variable "product" {
  description = "Product this datastore belongs to. Pinned to \"plugin-fees\" by validation: the derived name (plugin-fees-{env}-valkey) and the derived secret path (plugin-fees-{env}-valkey/auth-token) ARE the cross-stack discovery contract. A different value here silently produces resources the plugin-fees Helm release cannot find. The \"plugin-\" prefix is part of the chart name and is kept verbatim, matching the sibling documentdb and msk roots. A second product gets its own directory under examples/aws/products, not a different value here."
  type        = string
  default     = "plugin-fees"

  validation {
    condition     = var.product == "plugin-fees"
    error_message = "The product must be \"plugin-fees\". This root stack is the plugin-fees Valkey datastore; every name and secret path it produces is derived from it. To provision Valkey for another product, copy this directory to examples/aws/products/<product>/valkey instead."
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
  description = "\"dedicated\" creates a Valkey replication group owned by plugin-fees (plugin-fees-{env}-valkey). \"shared\" creates nothing and resolves the replication group owned by products/shared-resources/valkey, looked up by name: shared-{env}-valkey plus the secret shared-{env}-valkey/auth-token. In shared mode this stack resolves no VPC, no subnets and no EKS security group, and plans to zero resources."
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
# "lerian" product label — not "plugin-fees", and not "shared" either (that one
# labels the shared DATASTORE tier in products/shared-resources). Deriving them
# from module.naming here would produce plugin-fees-{env}-vpc /
# plugin-fees-{env}-eks, which do not exist — which is why this root stack does
# not call the naming module at all.
################################################################################

variable "vpc_name" {
  description = "tag:Name of the VPC the replication group is placed in. Leave empty (the default) to DERIVE \"lerian-{environment}-vpc\", which is what infra-base/vpc creates and exports as its vpc_name output."
  type        = string
  default     = ""
}

variable "subnet_tag_type" {
  description = "Value of the tag:Type used to select the subnets for the cache subnet group. infra-base/vpc tags its three database subnets with Type=database, which is the lookup contract."
  type        = string
  default     = "database"
}

################################################################################
# Ingress
#
# Same two-source model as products/shared-resources/valkey, for the same
# reason: the plugin-fees workloads run on the EKS nodes, and the replication
# group has to be reachable from them on the first apply, before anyone has
# wired a security group by hand.
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
  description = "Extra security group IDs allowed to reach the replication group on its port. Merged with the EKS node security group when eks_node_security_group_lookup_enabled is true."
  type        = list(string)
  default     = []
}

variable "allowed_cidr_blocks" {
  description = "Extra CIDR blocks allowed to reach the replication group on its port. Merged with the private subnet CIDRs when allow_private_subnet_cidr_ingress is true."
  type        = list(string)
  default     = []
}

variable "allow_private_subnet_cidr_ingress" {
  description = "Allow the CIDR blocks of the Type=private subnets to reach the replication group. This is the DEFAULT ingress path and the reason this stack can be applied before infra-base/eks exists. It is strictly tighter than the VPC-CIDR fallback the module ships, which additionally covers the public subnets. Set it to false once the EKS node security group is being resolved, to move to security-group-only ingress."
  type        = bool
  default     = true
}

variable "eks_node_security_group_lookup_enabled" {
  description = "Resolve the EKS node security group by tag and allow it on the replication group. Safe to leave true before infra-base/eks exists: the lookup uses data \"aws_security_groups\" (PLURAL), which returns an empty list rather than failing the plan, so this stack stays appliable and starts producing the rule on the first apply after the cluster exists."
  type        = bool
  default     = true
}

variable "eks_cluster_name" {
  description = "Name of the EKS cluster whose node security group is resolved. Leave empty (the default) to DERIVE \"lerian-{environment}-eks\" — the cluster belongs to infra-base and carries the \"lerian\" product label, NOT \"plugin-fees\". The lookup matches the node security group by tag:Name = \"{cluster}-node\", which is what terraform-aws-modules/eks sets."
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
  description = "Valkey engine version."
  type        = string
  default     = "7.2"
}

variable "parameter_group_family" {
  description = "Valkey parameter group family. Must match engine_version."
  type        = string
  default     = "valkey7"
}

variable "port" {
  description = "Port the cache nodes accept connections on. The plugin-fees chart keeps host and port SPLIT — MULTI_TENANT_REDIS_HOST is a BARE hostname and MULTI_TENANT_REDIS_PORT carries the port (templates/fees/configmap.yaml:104-105). This is the opposite of the midaz chart, whose REDIS_HOST embeds \"host:port\" in one string. Do not copy the midaz shape here."
  type        = number
  default     = 6379
}

################################################################################
# Sizing and availability
################################################################################

variable "node_type" {
  description = "Valkey node type. cache.t4g.micro is the cheapest usable size and is the intended dev value."
  type        = string
  default     = "cache.t4g.micro"
}

variable "num_cache_clusters" {
  description = "Number of cache clusters (primary plus replicas) in the replication group. Must be at least 2 when multi_az_enabled is true."
  type        = number
  default     = 1
}

variable "automatic_failover_enabled" {
  description = "Promote a replica automatically when the primary fails. Required when multi_az_enabled is true, and impossible with a single cache cluster."
  type        = bool
  default     = false
}

variable "multi_az_enabled" {
  description = "Spread the replication group across availability zones. Requires num_cache_clusters >= 2 and automatic_failover_enabled = true."
  type        = bool
  default     = false
}

variable "snapshot_retention_limit" {
  description = "Days ElastiCache retains automatic snapshots. 0 means no automatic snapshots. The tenant connection-pool registry is a CACHE, not a system of record — it can be rebuilt from the tenant-manager service — so there is nothing here worth a nightly snapshot in dev."
  type        = number
  default     = 0
}

################################################################################
# Security
################################################################################

variable "transit_encryption_enabled" {
  description = "Enable in-transit encryption on the replication group."
  type        = bool
  default     = true
}

variable "transit_encryption_mode" {
  description = "Transit encryption mode: \"preferred\" accepts both TLS and plaintext clients, \"required\" accepts TLS only. This value is what the helm_values output turns into MULTI_TENANT_REDIS_TLS. Note that plugin-fees and tracer disagree on the CHART default for that key — plugin-fees defaults it to \"false\" (values.yaml:215), tracer to \"true\" (values.yaml:251) — and neither default describes the server. The Terraform value does, and is the one to wire."
  type        = string
  default     = "preferred"

  validation {
    condition     = contains(["preferred", "required"], var.transit_encryption_mode)
    error_message = "The transit_encryption_mode must be either 'preferred' or 'required'."
  }
}

variable "auth_token_enabled" {
  description = "Make ElastiCache ENFORCE the auth token. The token is generated and stored in Secrets Manager either way; this only decides whether the server requires it. Defaults to false so a first apply cannot lock the registry out. plugin-fees ships the client-side knob explicitly: MULTI_TENANT_REDIS_PASSWORD is a named, optional key in the chart Secret (templates/fees/secrets.yaml:28-30, guarded on the value being non-empty) and is declared in values.yaml:246 — so enabling it is a tfvars change plus a values change, with no chart change needed. Rehearse it in stg first."
  type        = bool
  default     = false
}

################################################################################
# Maintenance
################################################################################

variable "maintenance_window" {
  description = "Weekly maintenance window, ddd:hh24:mi-ddd:hh24:mi in UTC."
  type        = string
  default     = "mon:00:00-mon:03:00"
}

variable "apply_immediately" {
  description = "Apply modifications immediately instead of waiting for the maintenance window."
  type        = bool
  default     = false
}
