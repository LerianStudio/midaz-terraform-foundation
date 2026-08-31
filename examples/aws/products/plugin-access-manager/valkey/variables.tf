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
  description = "Product this datastore belongs to. Pinned to \"plugin-access-manager\" by validation: the derived name (plugin-access-manager-{env}-valkey) and the derived secret path (plugin-access-manager-{env}-valkey/auth-token) ARE the cross-stack discovery contract. A different value here silently produces resources the plugin-access-manager Helm release cannot find. A second product gets its own directory under examples/aws/products, not a different value here."
  type        = string
  default     = "plugin-access-manager"

  validation {
    condition     = var.product == "plugin-access-manager"
    error_message = "The product must be \"plugin-access-manager\". This root stack is the plugin-access-manager Valkey datastore; every name and secret path it produces is derived from it. To provision Valkey for another product, copy this directory to examples/aws/products/<product>/valkey instead."
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
  description = "\"dedicated\" creates a Valkey replication group owned by plugin-access-manager (plugin-access-manager-{env}-valkey). \"shared\" creates nothing and resolves the replication group owned by products/shared-resources/valkey, looked up by name: shared-{env}-valkey plus the secret shared-{env}-valkey/auth-token. In shared mode this stack resolves no VPC, no subnets and no EKS security group, and plans to zero resources."
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
# "lerian" product label — not "plugin-access-manager", and not "shared" either (that one
# labels the shared DATASTORE tier in products/shared-resources). Deriving them
# from module.naming here would produce plugin-access-manager-{env}-vpc /
# plugin-access-manager-{env}-eks, which do not exist — which is why this root stack does
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
# reason: the plugin-access-manager workloads run on the EKS nodes, and the replication group has to be
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
  description = "Name of the EKS cluster whose node security group is resolved. Leave empty (the default) to DERIVE \"lerian-{environment}-eks\" — the cluster belongs to infra-base and carries the \"lerian\" product label, NOT \"plugin-access-manager\". The lookup matches the node security group by tag:Name = \"{cluster}-node\", which is what terraform-aws-modules/eks sets."
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
  description = "Port the cache nodes accept connections on. CRITICAL: this chart takes a BARE host in the REDIS_HOST values key and CONCATENATES the port itself — templates/auth/configmap.yaml:24 and templates/identity/configmap.yaml:54 both render printf \"%s:%s\" REDIS_HOST REDIS_PORT. Passing \"host:6379\" into the values key produces \"host:6379:6379\" in the ConfigMap. This is the exact OPPOSITE of the midaz chart, where REDIS_HOST must already carry the port."
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
  description = "Days ElastiCache retains automatic snapshots. 0 means no automatic snapshots."
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
  description = "Transit encryption mode: \"preferred\" accepts both TLS and plaintext clients, \"required\" accepts TLS only. The chart does expose a REDIS_TLS key on both the auth and the identity ConfigMap, so this value has somewhere to land; it is kept \"preferred\" because REDIS_CA_CERT also exists and nothing in this repository distributes the ElastiCache CA bundle into the pods."
  type        = string
  default     = "preferred"

  validation {
    condition     = contains(["preferred", "required"], var.transit_encryption_mode)
    error_message = "The transit_encryption_mode must be either 'preferred' or 'required'."
  }
}

variable "auth_token_enabled" {
  description = "Make ElastiCache ENFORCE the auth token. The token is generated and stored in Secrets Manager either way; this only decides whether the server requires it. Kept false, and here there is a concrete blocker beyond the usual one: the chart sends a Redis USERNAME (REDIS_USER, default \"auth\" on the auth component and \"identity\" on the identity component). ElastiCache auth tokens are the legacy password-only AUTH, with no username; a client that sends AUTH <user> <token> against a token-protected group is rejected. Enforcing the token therefore requires ElastiCache RBAC users, which this module does not create."
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
