module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = var.name
  cidr = var.vpc_cidr
  azs  = var.availability_zones

  public_subnets   = [for k, v in range(3) : cidrsubnet(var.vpc_cidr, 8, k)]
  private_subnets  = [for k, v in range(3) : cidrsubnet(var.vpc_cidr, 8, k + 3)]
  database_subnets = [for k, v in range(3) : cidrsubnet(var.vpc_cidr, 8, k + 6)]

  private_subnet_names  = [for az in var.availability_zones : "${var.name}-private-subnet-${split("-", az)[2]}"]
  public_subnet_names   = [for az in var.availability_zones : "${var.name}-public-subnet-${split("-", az)[2]}"]
  database_subnet_names = [for az in var.availability_zones : "${var.name}-database-subnet-${split("-", az)[2]}"]

  enable_nat_gateway     = var.enable_nat_gateway
  single_nat_gateway     = var.single_nat_gateway
  one_nat_gateway_per_az = var.one_nat_gateway_per_az

  enable_dns_hostnames = var.enable_dns_hostnames
  enable_dns_support   = var.enable_dns_support

  enable_flow_log                      = var.flow_logs_enabled
  create_flow_log_cloudwatch_log_group = var.flow_logs_enabled
  create_flow_log_cloudwatch_iam_role  = var.flow_logs_enabled

  private_subnet_tags = {
    Type = "private"
  }

  public_subnet_tags = {
    Type = "public"
  }

  database_subnet_tags = {
    Type = "database"
  }

  tags = merge({
    Environment = lower(var.environment)
    ManagedBy   = "Terraform"
    Resource    = var.resource_tags["vpc"]
  }, var.additional_tags)
}

module "vpc_endpoints" {
  count   = var.vpc_endpoint_enabled ? 1 : 0
  source  = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"
  version = "~> 5.0"

  vpc_id                     = module.vpc.vpc_id
  create_security_group      = true
  security_group_name_prefix = "${var.name}-security-group-vpc-endpoints"
  security_group_description = "VPC endpoint security group"
  security_group_rules = {
    ingress_https = {
      description = "HTTPS from VPC"
      cidr_blocks = [module.vpc.vpc_cidr_block]
    }
  }

  endpoints = {
    rds = {
      service             = "rds"
      service_type        = "Interface"
      subnet_ids          = var.vpc_endpoint_enabled ? module.vpc.private_subnets : []
      security_group_ids  = var.vpc_endpoint_enabled ? aws_security_group.database[*].id : []
      private_dns_enabled = true
      tags = merge({
        Name        = "${var.name}-vpc-endpoint-rds"
        Environment = lower(var.environment)
        ManagedBy   = "Terraform"
        Resource    = var.resource_tags["vpc_endpoint"]
      }, var.additional_tags)
    },
    secretsmanager = {
      service             = "secretsmanager"
      service_type        = "Interface"
      subnet_ids          = var.vpc_endpoint_enabled ? module.vpc.private_subnets : []
      security_group_ids  = var.vpc_endpoint_enabled ? aws_security_group.database[*].id : []
      private_dns_enabled = true
      tags = merge({
        Name        = "${var.name}-vpc-endpoint-secretsmanager"
        Environment = lower(var.environment)
        ManagedBy   = "Terraform"
        Resource    = var.resource_tags["vpc_endpoint"]
      }, var.additional_tags)
    },
    elasticache = {
      service             = "elasticache"
      service_type        = "Interface"
      subnet_ids          = var.vpc_endpoint_enabled ? module.vpc.private_subnets : []
      security_group_ids  = var.vpc_endpoint_enabled ? aws_security_group.database[*].id : []
      private_dns_enabled = true
      tags = merge({
        Name        = "${var.name}-vpc-endpoint-elasticache"
        Environment = lower(var.environment)
        ManagedBy   = "Terraform"
        Resource    = var.resource_tags["vpc_endpoint"]
      }, var.additional_tags)
    }
  }

  tags = merge({
    Name        = "${var.name}-vpc-endpoint"
    Environment = lower(var.environment)
    ManagedBy   = "Terraform"
    Resource    = var.resource_tags["vpc_endpoint"]
  }, var.additional_tags)
}

resource "aws_network_acl" "database" {
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.database_subnets

  # Allow inbound from first private subnet
  ingress {
    rule_no    = 100
    action     = "allow"
    cidr_block = cidrsubnet(var.vpc_cidr, 8, 3)
    protocol   = "-1"
    from_port  = 0
    to_port    = 0
  }

  # Allow inbound from second private subnet
  ingress {
    rule_no    = 110
    action     = "allow"
    cidr_block = cidrsubnet(var.vpc_cidr, 8, 4)
    protocol   = "-1"
    from_port  = 0
    to_port    = 0
  }

  # Allow inbound from third private subnet
  ingress {
    rule_no    = 120
    action     = "allow"
    cidr_block = cidrsubnet(var.vpc_cidr, 8, 5)
    protocol   = "-1"
    from_port  = 0
    to_port    = 0
  }

  # Allow outbound to first private subnet
  egress {
    rule_no    = 100
    action     = "allow"
    cidr_block = cidrsubnet(var.vpc_cidr, 8, 3)
    protocol   = "-1"
    from_port  = 0
    to_port    = 0
  }

  # Allow outbound to second private subnet
  egress {
    rule_no    = 110
    action     = "allow"
    cidr_block = cidrsubnet(var.vpc_cidr, 8, 4)
    protocol   = "-1"
    from_port  = 0
    to_port    = 0
  }

  # Allow outbound to third private subnet
  egress {
    rule_no    = 120
    action     = "allow"
    cidr_block = cidrsubnet(var.vpc_cidr, 8, 5)
    protocol   = "-1"
    from_port  = 0
    to_port    = 0
  }

  tags = merge({
    Name        = "${var.name}-database-subnets-nacl"
    Environment = lower(var.environment)
    ManagedBy   = "Terraform"
    Resource    = var.resource_tags["network_acl"]
  }, var.additional_tags)
}

resource "aws_security_group" "database" {
  count = var.vpc_endpoint_enabled ? 1 : 0

  name_prefix = "${var.name}-database"
  description = "Allow database inbound traffic"
  vpc_id      = module.vpc.vpc_id

  # PostgreSQL port
  ingress {
    description = "PostgreSQL from VPC"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [module.vpc.vpc_cidr_block]
  }

  # Redis port for Valkey
  ingress {
    description = "Redis/Valkey from VPC"
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = [module.vpc.vpc_cidr_block]
  }

  tags = merge({
    Name        = "${var.name}-security-group-database"
    Environment = lower(var.environment)
    ManagedBy   = "Terraform"
    Resource    = var.resource_tags["vpc_endpoint"]
  }, var.additional_tags)
}