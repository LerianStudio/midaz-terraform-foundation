variable "region" {
  description = "AWS region where the VPC is created. Must be the region the availability_zones belong to."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", var.region))
    error_message = "The region must be a valid AWS region identifier, e.g. us-east-1 or sa-east-1."
  }
}

variable "product" {
  description = "Product this stack belongs to. Keep the default \"lerian\": this VPC is shared base infrastructure consumed by every product, and \"lerian\" is what makes the derived names (lerian-{env}-vpc, lerian-{env}-eks) match the defaults the datastore modules and the infra-base/eks stack look up."
  type        = string
  default     = "lerian"
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
  description = "Additional tags merged on top of the standard Lerian tag set (Product, Environment, ManagedBy, Repository). Applied to every resource in this stack."
  type        = map(string)
  default     = {}
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC. The subnet layout carves nine /24-equivalent blocks out of it (3 public, 3 private, 3 database), so the prefix must be /20 or wider."
  type        = string
  default     = "10.50.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "The vpc_cidr must be a valid IPv4 CIDR block, e.g. 10.50.0.0/16."
  }

  validation {
    condition     = can(tonumber(split("/", var.vpc_cidr)[1])) && tonumber(split("/", var.vpc_cidr)[1]) <= 20
    error_message = "The vpc_cidr prefix must be /20 or wider: the subnet math adds 8 bits, so a narrower block cannot hold the nine subnets this stack creates."
  }
}

variable "availability_zones" {
  description = "Availability zones for the subnet tiers. Exactly three are required, in the same region as var.region."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]

  validation {
    condition     = length(var.availability_zones) == 3
    error_message = "Exactly three availability zones are required: the subnet math reserves three /24 blocks per tier (offsets 0-2 public, 3-5 private, 6-8 database) and the database network ACL is derived from that layout."
  }
}

variable "enable_nat_gateway" {
  description = "Provision NAT Gateways so private and database subnets can reach the internet. Required for EKS nodes to pull images and reach the EKS control plane endpoint when it is private-only."
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = "Provision ONE NAT Gateway shared by all private subnets instead of one per AZ. Cheap and correct for dev (about one third of the hourly cost); a single point of failure and a cross-AZ data charge in production, so keep it false for prd."
  type        = bool
  default     = false
}

variable "one_nat_gateway_per_az" {
  description = "Provision exactly one NAT Gateway per availability zone. This is the production posture: an AZ outage takes down only its own egress path."
  type        = bool
  default     = false
}

variable "enable_dns_hostnames" {
  description = "Enable DNS hostnames in the VPC. Required for private hosted zone resolution and for VPC endpoint private DNS."
  type        = bool
  default     = true
}

variable "enable_dns_support" {
  description = "Enable the Amazon-provided DNS server in the VPC. Required for private hosted zone resolution."
  type        = bool
  default     = true
}

variable "flow_logs_enabled" {
  description = "Enable VPC Flow Logs to CloudWatch Logs. The log group and the IAM role are named from the naming module so dev, stg and prd can coexist in one account."
  type        = bool
  default     = true
}

variable "flow_logs_retention_days" {
  description = "CloudWatch Logs retention for the flow log group. Flow logs are the dominant cost of this stack after NAT: keep it short in dev (7 days) and long enough for a forensic window in prd (90 days or more). 0 means never expire."
  type        = number
  default     = 30

  validation {
    condition     = contains([0, 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.flow_logs_retention_days)
    error_message = "The flow_logs_retention_days must be one of the CloudWatch Logs retention values: 0, 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653."
  }
}

variable "vpc_endpoint_enabled" {
  description = "Create the interface VPC endpoints listed in var.interface_endpoint_services. Interface endpoints bill per hour PER AZ, so this is the switch to turn off in a cost-constrained environment. It does not affect the S3 gateway endpoint, which is free."
  type        = bool
  default     = true
}

variable "interface_endpoint_services" {
  description = <<-EOT
    AWS services to expose as interface VPC endpoints in the private subnets.

    COST: each interface endpoint costs roughly USD 0.01 per hour PER AZ plus data
    processing, so one service across three AZs is about USD 22 per month before
    traffic. The three defaults are the ones every Lerian product needs on the data
    path (rds, secretsmanager, elasticache).

    kms and sts are deliberately NOT default. Both are reachable through the NAT
    Gateway that this stack already provisions, so adding them buys private-only
    routing and lower NAT data charges, not new capability:
      - sts: IRSA token exchange. Called once per pod start, a negligible amount of
        traffic, so an endpoint pays for itself only in a no-NAT VPC.
      - kms: called on every Secrets Manager decrypt and on RDS/DocumentDB storage
        key operations. Worth enabling in prd if NAT data processing shows up in the
        bill, and mandatory if the private subnets ever lose their NAT route.
    Add them per environment in envs/*.tfvars once that trade-off applies.
  EOT
  type        = list(string)
  default     = ["rds", "secretsmanager", "elasticache"]

  validation {
    condition     = alltrue([for s in var.interface_endpoint_services : can(regex("^[a-z0-9][a-z0-9.-]*$", s))])
    error_message = "Each interface endpoint service must be the AWS service short name, lowercase, e.g. rds, secretsmanager, kms, sts, ecr.api."
  }
}

variable "enable_s3_gateway_endpoint" {
  description = "Create the S3 gateway VPC endpoint on the private and database route tables. Gateway endpoints have NO hourly charge and NO data processing charge, and they keep S3 traffic off the NAT Gateway, where the same bytes would be billed. Lerian products that read or write S3 directly (reporter, fetcher, bc-correios) make this a straight cost reduction, so it defaults to on."
  type        = bool
  default     = true
}

variable "database_nacl_peer_cidrs" {
  description = <<-EOT
    Extra CIDR blocks allowed through the database subnet network ACL, on top of
    this VPC's own private and database subnets.

    For peered VPCs whose workloads read a datastore here. The datastore's
    security group is not enough on its own: a network ACL is evaluated on every
    packet that crosses the subnet boundary, so a peer the security group admits
    is still dropped at this layer. The symptom is a connection timeout while
    peering is active, routes exist on both sides and the security group already
    names the peer CIDR -- which reads as a routing fault and is not one.

    Network ACLs are stateless, so each block is opened in both directions.
  EOT
  type        = list(string)
  default     = []

  # The database ACL already carries six fixed rules in each direction (100-120
  # for the private subnets, 200-220 for the database ones) and each peer adds
  # one more per direction. AWS allows 20 entries per direction by default, so
  # fourteen peers is the last count that applies. Past it the apply fails
  # partway through, with some rules created and the ACL in neither the old
  # shape nor the new one. The quota is adjustable to 40 on request; raise this
  # bound together with it.
  validation {
    condition     = length(var.database_nacl_peer_cidrs) <= 14
    error_message = "database_nacl_peer_cidrs takes at most 14 entries: the database network ACL already holds six rules per direction and AWS allows 20 by default."
  }

  # Each entry lands in cidr_block, which is IPv4 only -- an IPv6 prefix needs
  # ipv6_cidr_block instead, and the rules here do not set it. cidrnetmask is
  # the shortest total test: it is defined for IPv4 and errors on IPv6, on a
  # null element and on anything that is not a prefix at all, so `can` around it
  # refuses all three at plan time rather than midway through the apply.
  validation {
    condition     = alltrue([for cidr in var.database_nacl_peer_cidrs : can(cidrnetmask(cidr))])
    error_message = "Every entry in database_nacl_peer_cidrs must be an IPv4 CIDR block, such as 10.59.0.0/16."
  }
}

variable "cluster_name" {
  description = "EKS cluster name used in the kubernetes.io/cluster/<name> subnet tags. Leave empty (the default) to DERIVE \"{product}-{environment}-eks\", which is exactly the name the infra-base/eks stack derives for itself. Only override it when pointing these subnets at a cluster that was not created by infra-base/eks — an override that does not match the real cluster name leaves the cluster unable to discover its own subnets."
  type        = string
  default     = ""
}
