provider "aws" {
  region = "us-east-2" # ou outra região
}

# Main EKS cluster configuration using the AWS EKS Terraform module
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.36"

  # Basic cluster settings including name and Kubernetes version
  cluster_name    = var.name
  cluster_version = var.cluster_version

  # API server endpoint access - enables private access and configurable public access
  cluster_endpoint_private_access      = var.cluster_endpoint_private_access
  cluster_endpoint_public_access       = var.cluster_endpoint_public_access
  cluster_endpoint_public_access_cidrs = var.allowed_api_access_cidrs

  # Automatically grants admin permissions to the AWS IAM entity creating the cluster
  enable_cluster_creator_admin_permissions = var.enable_cluster_creator_admin_permissions

  # Define IAM roles that can access the cluster and their permission levels
  access_entries = {
    admin = {
      kubernetes_groups = []
      principal_arn     = aws_iam_role.admin_role.arn

      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            namespaces = []
            type       = "cluster"
          }
        }
      }
    }
    developer = {
      kubernetes_groups = []
      principal_arn     = aws_iam_role.developer_role.arn

      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
          access_scope = {
            namespaces = []
            type       = "cluster"
          }
        }
      }
    }
  }

  # Configure KMS encryption for Kubernetes secrets
  cluster_encryption_config = {
    provider_key_arn = module.eks_kms_key.key_arn
    resources        = ["secrets"]
  }

  # Enable comprehensive control plane logging for audit and troubleshooting
  cluster_enabled_log_types = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler"
  ]

  # Install and configure essential cluster addons with latest versions
  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
    }
    metrics-server = {
      most_recent = true
    }
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = module.ebs_csi_irsa_role.iam_role_arn
    }
  }

  # Network configuration using existing VPC and private subnets
  vpc_id     = data.aws_vpc.selected.id
  subnet_ids = data.aws_subnets.private.ids

  # Default configuration for all managed node groups
  eks_managed_node_group_defaults = {
    ami_type                              = var.ami_type
    instance_types                        = var.instance_types
    attach_cluster_primary_security_group = var.attach_cluster_primary_security_group
    create_security_group                 = var.create_security_group
  }

  # Security group rules for node-to-node communication and external access
  node_security_group_additional_rules = {
    ingress_self_all = {
      description = "Node to node all ports/protocols"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
    egress_vpc = {
      description = "Allow outbound traffic to VPC CIDR"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "egress"
      cidr_blocks = [data.aws_vpc.selected.cidr_block]
    }
    egress_all = {
      description = "Allow outbound traffic to internet"
      protocol    = "tcp"
      from_port   = 443
      to_port     = 443
      type        = "egress"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  # Configure the default managed node group with autoscaling settings
  eks_managed_node_groups = {
    default = {
      name                     = "${var.name}-default-nodepool"
      use_name_prefix          = false
      iam_role_name            = "${var.name}-default-nodepool"
      iam_role_use_name_prefix = false
      min_size                 = var.min_size
      max_size                 = var.max_size
      desired_size             = var.desired_size
      instance_types           = var.instance_types
      capacity_type            = var.capacity_type

      labels = {
        Environment = lower(var.environment)
        GithubRepo  = "midaz-terraform-foundation"
      }

      tags = merge({
        Environment = lower(var.environment)
        ManagedBy   = "Terraform"
      }, var.additional_tags)
    }
  }

  # Global tags applied to all resources created by this module
  tags = merge({
    Environment = lower(var.environment)
    ManagedBy   = "Terraform"
  }, var.additional_tags)
}
