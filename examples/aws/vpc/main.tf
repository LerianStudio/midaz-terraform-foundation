locals {
  environment          = lower(var.environment)
  name                 = var.name
  vpc_cidr             = var.vpc_cidr
  azs                  = ["us-east-1a", "us-east-1b", "us-east-1c"]
  vpc_endpoint_enabled = var.vpc_endpoint_enabled
  flow_logs_enabled    = var.flow_logs_enabled
  tags = merge({
    Name        = "vpc-${local.name}-${local.environment}"
    Environment = local.environment
    ManagedBy   = "Terraform"
  }, var.additional_tags)
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = local.name
  cidr = local.vpc_cidr
  azs  = local.azs

  private_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k)]
  public_subnets   = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 4)]
  database_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 8)]

  private_subnet_names  = [for az in local.azs : "Private Subnet ${az}"]
  public_subnet_names   = [for az in local.azs : "Public Subnet ${az}"]
  database_subnet_names = [for az in local.azs : "DB Subnet ${az}"]

  enable_nat_gateway     = true
  single_nat_gateway     = local.environment == "hml"
  one_nat_gateway_per_az = local.environment == "prod"

  enable_dns_hostnames = true
  enable_dns_support   = true

  enable_flow_log                      = local.flow_logs_enabled
  create_flow_log_cloudwatch_log_group = local.flow_logs_enabled
  create_flow_log_cloudwatch_iam_role  = local.flow_logs_enabled

  tags = merge(local.tags, {
    Resource = "vpc"
  })
}



module "vpc_endpoints" {
  count   = local.vpc_endpoint_enabled ? 1 : 0
  source  = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"
  version = "~> 5.0"

  vpc_id                     = module.vpc.vpc_id
  create_security_group      = true
  security_group_name_prefix = "${local.name}-vpc-endpoints-"
  security_group_description = "VPC endpoint security group"
  security_group_rules = {
    ingress_https = {
      description = "HTTPS from VPC"
      cidr_blocks = [module.vpc.vpc_cidr_block]
    }
  }

  endpoints = local.vpc_endpoint_enabled ? {
    rds = {
      service            = "rds"
      service_type       = "Interface"
      subnet_ids         = module.vpc.private_subnets
      security_group_ids = aws_security_group.rds[*].id
    },
    secretsmanager = {
      service             = "secretsmanager"
      service_type        = "Interface"
      private_dns_enabled = true
      tags                = local.tags
    }
  } : {}

  tags = merge(local.tags, {
    Resource = "vpc-endpoint"
  })
}



resource "aws_network_acl" "database" {
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.database_subnets
  ingress {
    rule_no    = 100
    action     = "allow"
    cidr_block = cidrsubnet(local.vpc_cidr, 8, 0)
    protocol   = "-1"
    from_port  = 0
    to_port    = 0
  }

  egress {
    rule_no    = 100
    action     = "allow"
    cidr_block = cidrsubnet(local.vpc_cidr, 8, 1)
    protocol   = "-1"
    from_port  = 0
    to_port    = 0
  }

  tags = merge(local.tags, {
    Resource = "network-acl"
  })
}

resource "aws_security_group" "rds" {
  count = local.vpc_endpoint_enabled ? 1 : 0

  name_prefix = "${local.name}-rds"
  description = "Allow PostgreSQL inbound traffic"
  vpc_id      = module.vpc.vpc_id
  ingress {
    description = "TLS from VPC"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [module.vpc.vpc_cidr_block]
  }

  tags = local.tags
}