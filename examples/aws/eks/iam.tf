# IAM role for EKS cluster administrators with full cluster access
resource "aws_iam_role" "admin_role" {
  name                  = "${var.name}-admin-role"
  force_detach_policies = true

  # Trust policy allowing EKS service to assume this role
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
      }
    ]
  })

  tags = merge({
    Environment = lower(var.environment)
    ManagedBy   = "Terraform"
  }, var.additional_tags)
}

# IAM role for developers with read-only access to the EKS cluster
resource "aws_iam_role" "developer_role" {
  name                  = "${var.name}-developer-role"
  force_detach_policies = true

  # Trust policy allowing EKS service to assume this role
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
      }
    ]
  })

  tags = merge({
    Environment = lower(var.environment)
    ManagedBy   = "Terraform"
  }, var.additional_tags)
}

# IAM role for EBS CSI Driver
module "ebs_csi_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.33"

  role_name             = "${var.name}-ebs-csi"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }

  # Apply standard tags plus any additional tags provided
  tags = merge({
    Environment = lower(var.environment)
    ManagedBy   = "Terraform"
  }, var.additional_tags)
}

# IAM role for Cluster Autoscaler
module "cluster_autoscaler_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.33"
  count   = var.create_autoscaler_role ? 1 : 0

  role_name = "${var.name}-cluster-autoscaler"

  attach_cluster_autoscaler_policy = true
  cluster_autoscaler_cluster_ids   = [module.eks.cluster_name]

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:cluster-autoscaler"]
    }
  }

  tags = merge({
    Environment = lower(var.environment)
    ManagedBy   = "Terraform"
  }, var.additional_tags)
}

# IAM role for AWS Load Balancer Controller
module "aws_load_balancer_controller_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.33"
  count   = var.create_load_balancer_controller_role ? 1 : 0

  role_name = "${var.name}-aws-load-balancer-controller"

  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }

  tags = merge({
    Environment = lower(var.environment)
    ManagedBy   = "Terraform"
  }, var.additional_tags)
}
