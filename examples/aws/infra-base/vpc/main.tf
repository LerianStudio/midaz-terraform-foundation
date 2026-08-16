################################################################################
# Lerian shared base VPC — infra-base
#
# One VPC per environment, shared by every Lerian product deployed into that
# environment. product is "lerian" (not midaz, not reporter) because this is base
# infrastructure: the products consume it, they do not own it.
#
# Names come from the naming module, so dev, stg and prd can be applied into the
# SAME AWS account without colliding: lerian-dev-vpc, lerian-stg-vpc,
# lerian-prd-vpc, and every derived resource (flow log group, flow log IAM role,
# endpoint security group, database network ACL) carries the same prefix.
#
# Subnet layout, three tiers times three AZs, carved out of var.vpc_cidr:
#
#   public   offsets 0,1,2  -> ALB/NLB, NAT Gateways
#   private  offsets 3,4,5  -> EKS nodes, interface VPC endpoints
#   database offsets 6,7,8  -> RDS, DocumentDB, ElastiCache, Amazon MQ
#
# The Type tag on each subnet (public|private|database) is a CONTRACT, not
# decoration: every datastore module in examples/aws/_modules resolves its subnet
# group with `data "aws_subnets"` filtered on tags = { Type = "database" }.
# Renaming or dropping that tag breaks every datastore stack at plan time.
################################################################################

module "naming" {
  source = "../../_modules/naming"

  product     = var.product
  environment = var.environment
  component   = "vpc"
  extra_tags  = var.extra_tags
}

locals {
  # Subnet CIDRs are computed here rather than inline in the module call because
  # the database network ACL below has to reference the exact same blocks. Two
  # copies of this arithmetic is how the rules drift out of sync with the subnets.
  public_subnet_cidrs   = [for k in range(3) : cidrsubnet(var.vpc_cidr, 8, k)]
  private_subnet_cidrs  = [for k in range(3) : cidrsubnet(var.vpc_cidr, 8, k + 3)]
  database_subnet_cidrs = [for k in range(3) : cidrsubnet(var.vpc_cidr, 8, k + 6)]

  # CROSS-STACK CONTRACT with examples/aws/infra-base/eks.
  #
  # The kubernetes.io/cluster/<cluster_name> tags below are how an EKS cluster and
  # the AWS Load Balancer Controller discover the subnets they may use. The tag is
  # written by THIS stack, the cluster is created by ANOTHER stack, and nothing at
  # apply time cross-checks the two. When the names disagree the failure is silent:
  # the cluster comes up and load balancer provisioning fails with "no subnets
  # found" much later.
  #
  # So the name is derived, not typed. infra-base/eks derives its cluster name from
  # the same naming module with component = "eks", which yields the same string as
  # module.naming.prefix + "-eks" for the same product/environment pair. With the
  # mandated product = "lerian" both sides resolve to lerian-{env}-eks.
  cluster_name = var.cluster_name != "" ? var.cluster_name : "${module.naming.prefix}-eks"

  # Interface endpoints are gated by vpc_endpoint_enabled because they carry an
  # hourly charge per AZ. The S3 gateway endpoint is not: it is free.
  interface_endpoint_services = var.vpc_endpoint_enabled ? var.interface_endpoint_services : []
  create_endpoint_sg          = length(local.interface_endpoint_services) > 0

  interface_endpoints = {
    for service in local.interface_endpoint_services : service => {
      service             = service
      service_type        = "Interface"
      private_dns_enabled = true
      tags = merge(module.naming.tags, {
        Name = "${module.naming.name}-endpoint-${replace(service, ".", "-")}"
      })
    }
  }

  # Gateway endpoint: attached to route tables, not to subnets, and it takes no
  # security group. Private and database route tables only — public subnets reach
  # S3 through the internet gateway at no NAT cost, so there is nothing to save
  # there. distinct() because the VPC module falls back to returning the private
  # route table ids for database subnets when no dedicated database route table
  # exists, which would otherwise associate the same route table twice.
  gateway_endpoints = var.enable_s3_gateway_endpoint ? {
    s3 = {
      service      = "s3"
      service_type = "Gateway"
      route_table_ids = distinct(concat(
        module.vpc.private_route_table_ids,
        module.vpc.database_route_table_ids,
      ))
      tags = merge(module.naming.tags, {
        Name = "${module.naming.name}-endpoint-s3"
      })
    }
  } : {}

  endpoints = merge(local.interface_endpoints, local.gateway_endpoints)
}

################################################################################
# VPC
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = module.naming.name
  cidr = var.vpc_cidr
  azs  = var.availability_zones

  public_subnets   = local.public_subnet_cidrs
  private_subnets  = local.private_subnet_cidrs
  database_subnets = local.database_subnet_cidrs

  # AZ suffix only ("us-east-1a" -> "1a"), so the subnet name stays readable:
  # lerian-dev-vpc-private-subnet-1a.
  private_subnet_names  = [for az in var.availability_zones : "${module.naming.name}-private-subnet-${split("-", az)[2]}"]
  public_subnet_names   = [for az in var.availability_zones : "${module.naming.name}-public-subnet-${split("-", az)[2]}"]
  database_subnet_names = [for az in var.availability_zones : "${module.naming.name}-database-subnet-${split("-", az)[2]}"]

  enable_nat_gateway     = var.enable_nat_gateway
  single_nat_gateway     = var.single_nat_gateway
  one_nat_gateway_per_az = var.one_nat_gateway_per_az

  enable_dns_hostnames = var.enable_dns_hostnames
  enable_dns_support   = var.enable_dns_support

  # Flow logs. The module owns the log group and the IAM role, but both names are
  # forced through the naming module: use_name_prefix = false on the role and the
  # policy means the exact name is ours, which is required for two environments in
  # one account (IAM role names are account-global).
  enable_flow_log                                 = var.flow_logs_enabled
  create_flow_log_cloudwatch_log_group            = var.flow_logs_enabled
  create_flow_log_cloudwatch_iam_role             = var.flow_logs_enabled
  flow_log_cloudwatch_log_group_name_suffix       = module.naming.name
  flow_log_cloudwatch_log_group_retention_in_days = var.flow_logs_retention_days
  vpc_flow_log_iam_role_name                      = "${module.naming.name}-flow-logs"
  vpc_flow_log_iam_role_use_name_prefix           = false
  vpc_flow_log_iam_policy_name                    = "${module.naming.name}-flow-logs"
  vpc_flow_log_iam_policy_use_name_prefix         = false

  # The default security group of a fresh VPC allows all traffic between anything
  # attached to it. Nothing here uses it; emptying it removes an implicit
  # allow-all path that any future ENI created without an explicit SG would land on.
  manage_default_security_group  = true
  default_security_group_name    = "${module.naming.name}-default"
  default_security_group_ingress = []
  default_security_group_egress  = []

  # Type is the lookup contract for the datastore modules. The kubernetes.io tags
  # are what EKS and the AWS Load Balancer Controller use for subnet discovery:
  # role/elb on public subnets for internet-facing load balancers, and
  # role/internal-elb on private subnets for internal ones.
  #
  # cluster/<name> = "shared" rather than "owned": these subnets are created and
  # destroyed by THIS stack, never by the cluster, and "shared" is the value AWS
  # documents for subnets a cluster uses but does not own. It also lets a second
  # cluster (a blue/green control-plane upgrade) reuse the same subnets, which
  # "owned" forbids.
  private_subnet_tags = {
    Type                                          = "private"
    "kubernetes.io/role/internal-elb"             = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }

  public_subnet_tags = {
    Type                                          = "public"
    "kubernetes.io/role/elb"                      = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }

  database_subnet_tags = {
    Type = "database"
  }

  tags = module.naming.tags
}

################################################################################
# Interface endpoint security group
#
# Interface endpoints terminate HTTPS on an ENI inside the private subnets, so the
# only ingress they need is 443 from the VPC. The upstream vpc-endpoints submodule
# can create this security group itself, but it applies create_before_destroy to
# it, which deadlocks against an exact (non-prefixed) name on replacement — and an
# exact name is exactly what the anti-collision rule requires here. Owning the
# resource keeps the naming contract and drops that trap.
#
# No egress rule is declared, which removes the default allow-all egress: an
# endpoint ENI answers requests, it does not originate them.
################################################################################

resource "aws_security_group" "vpc_endpoints" {
  count = local.create_endpoint_sg ? 1 : 0

  name        = "${module.naming.name}-endpoints"
  description = "HTTPS from the VPC to the interface VPC endpoints of ${module.naming.name}"
  vpc_id      = module.vpc.vpc_id

  tags = merge(module.naming.tags, {
    Name = "${module.naming.name}-endpoints"
  })
}

resource "aws_vpc_security_group_ingress_rule" "vpc_endpoints_https" {
  count = local.create_endpoint_sg ? 1 : 0

  security_group_id = aws_security_group.vpc_endpoints[0].id
  description       = "HTTPS from the VPC CIDR"
  cidr_ipv4         = module.vpc.vpc_cidr_block
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"

  tags = merge(module.naming.tags, {
    Name = "${module.naming.name}-endpoints-https"
  })
}

################################################################################
# VPC endpoints
################################################################################

module "vpc_endpoints" {
  count = length(local.endpoints) > 0 ? 1 : 0

  source  = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"
  version = "~> 5.0"

  vpc_id = module.vpc.vpc_id

  # Applied to every Interface endpoint in the map. Gateway endpoints ignore both.
  subnet_ids            = module.vpc.private_subnets
  create_security_group = false
  security_group_ids    = aws_security_group.vpc_endpoints[*].id

  endpoints = local.endpoints

  tags = module.naming.tags
}

################################################################################
# Database subnet network ACL
#
# Second line of defence behind the per-datastore security groups: a subnet-level
# deny for anything that is not a Lerian workload subnet.
#
# The database CIDRs are allowed alongside the private ones, and that is a FIX,
# not a widening. A network ACL is evaluated on every packet that crosses a subnet
# boundary, including database-subnet to database-subnet in another AZ — which is
# precisely the path used by RDS Multi-AZ replication, DocumentDB replica set
# traffic and ElastiCache replication. Allowing only the private subnets (the
# behaviour of examples/aws/vpc) leaves every multi-AZ datastore unable to
# replicate.
#
# Network ACLs are stateless, so each direction is declared explicitly, and
# protocol "-1" covers the ephemeral return ports.
################################################################################

resource "aws_network_acl" "database" {
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.database_subnets

  dynamic "ingress" {
    for_each = local.private_subnet_cidrs

    content {
      rule_no    = 100 + ingress.key * 10
      action     = "allow"
      cidr_block = ingress.value
      protocol   = "-1"
      from_port  = 0
      to_port    = 0
    }
  }

  dynamic "ingress" {
    for_each = local.database_subnet_cidrs

    content {
      rule_no    = 200 + ingress.key * 10
      action     = "allow"
      cidr_block = ingress.value
      protocol   = "-1"
      from_port  = 0
      to_port    = 0
    }
  }

  dynamic "egress" {
    for_each = local.private_subnet_cidrs

    content {
      rule_no    = 100 + egress.key * 10
      action     = "allow"
      cidr_block = egress.value
      protocol   = "-1"
      from_port  = 0
      to_port    = 0
    }
  }

  dynamic "egress" {
    for_each = local.database_subnet_cidrs

    content {
      rule_no    = 200 + egress.key * 10
      action     = "allow"
      cidr_block = egress.value
      protocol   = "-1"
      from_port  = 0
      to_port    = 0
    }
  }

  tags = merge(module.naming.tags, {
    Name = "${module.naming.name}-database-nacl"
  })
}
