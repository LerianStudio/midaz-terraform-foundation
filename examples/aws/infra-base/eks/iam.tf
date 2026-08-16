################################################################################
# Human access roles
#
# Both roles are assumable by any principal in the account that is allowed to
# call sts:AssumeRole on them, and are wired into the cluster through EKS access
# entries in main.tf (authentication_mode = "API", no aws-auth ConfigMap).
#
# Names come from module.naming: "midaz-eks-admin-role" style hardcoding is what
# prevented two environments from sharing an AWS account.
################################################################################

# Cluster administrators: AmazonEKSClusterAdminPolicy, cluster-wide.
resource "aws_iam_role" "admin_role" {
  name                  = "${module.naming.name}-admin-role"
  force_detach_policies = true

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

  tags = merge(module.naming.tags, {
    Name = "${module.naming.name}-admin-role"
  })
}

# Developers: AmazonEKSViewPolicy, read-only cluster-wide.
resource "aws_iam_role" "developer_role" {
  name                  = "${module.naming.name}-developer-role"
  force_detach_policies = true

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

  tags = merge(module.naming.tags, {
    Name = "${module.naming.name}-developer-role"
  })
}

################################################################################
# IRSA roles for cluster addons and controllers
#
# Only the IAM side lives here. Except for the EBS CSI driver (installed as an
# EKS addon in main.tf), the controllers themselves are installed with
# Helm/GitOps and must reference these role ARNs on their service accounts.
################################################################################

# EBS CSI driver — always created, consumed by the aws-ebs-csi-driver addon.
module "ebs_csi_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.33"

  role_name             = "${module.naming.name}-ebs-csi"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }

  tags = module.naming.tags
}

# Cluster Autoscaler — install with Helm/GitOps.
module "cluster_autoscaler_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.33"
  count   = var.create_autoscaler_role ? 1 : 0

  role_name = "${module.naming.name}-cluster-autoscaler"

  attach_cluster_autoscaler_policy = true
  cluster_autoscaler_cluster_ids   = [module.eks.cluster_name]

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:cluster-autoscaler"]
    }
  }

  tags = module.naming.tags
}

# AWS Load Balancer Controller — install with Helm/GitOps.
module "aws_load_balancer_controller_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.33"
  count   = var.create_load_balancer_controller_role ? 1 : 0

  role_name = "${module.naming.name}-aws-load-balancer-controller"

  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }

  tags = module.naming.tags
}

# ExternalDNS — publishes Service/Ingress records into a Route53 hosted zone.
# This is PUBLIC ingress DNS and has nothing to do with the datastores: there is
# no private zone in this repository (the datastore modules hand out raw AWS
# endpoints, because a CNAME breaks TLS hostname verification). The zone is
# whatever the operator points external_dns_hosted_zone_arns at, created outside
# this Terraform. Install with Helm/GitOps.
module "external_dns_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.33"
  count   = var.create_external_dns_role ? 1 : 0

  role_name = "${module.naming.name}-external-dns"

  attach_external_dns_policy    = true
  external_dns_hosted_zone_arns = var.external_dns_hosted_zone_arns

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:external-dns"]
    }
  }

  tags = module.naming.tags
}

# cert-manager — Route53 DNS-01 solver. Install with Helm/GitOps.
module "cert_manager_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.33"
  count   = var.create_cert_manager_role ? 1 : 0

  role_name = "${module.naming.name}-cert-manager"

  attach_cert_manager_policy    = true
  cert_manager_hosted_zone_arns = var.cert_manager_hosted_zone_arns

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["cert-manager:cert-manager"]
    }
  }

  tags = module.naming.tags
}
