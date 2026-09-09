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
# cert-manager -- install with Helm/GitOps.
#
# THE POLICY IS WRITTEN HERE INSTEAD OF TAKEN FROM THE MODULE, and the reason is
# one missing condition. `attach_cert_manager_policy = true` attaches the
# module's own document, which grants route53:ChangeResourceRecordSets on the
# given zones with NO condition at all -- so the service account can rewrite ANY
# record type in a zone it was only ever meant to write challenge records into,
# a client-facing A record included. On an estate whose ingress names live in
# that same zone, that is traffic redirection, not a hardening nicety.
#
# cert-manager only ever writes ONE kind of record for a DNS-01 challenge: a TXT
# at _acme-challenge.<name>. So the grant is restricted to TXT, which is the
# fine-grained control Route 53 documents for exactly this shape.
#
# ON ForAllValues, BECAUSE IT IS A TRAP WORTH NAMING. ForAllValues:StringEquals
# evaluates to TRUE when the condition key is absent from the request, so on many
# actions it is a fail-open guard. It is safe HERE because
# route53:ChangeResourceRecordSetsRecordTypes is derived from the request itself:
# a ChangeResourceRecordSets call always carries the record types it is changing,
# and there is no way to invoke it without them. Do not copy this operator onto
# an action whose key can be missing.
#
# The two read statements are unrestricted on purpose. GetChange polls the status
# of a change this role just made, and ListHostedZonesByName is how cert-manager
# finds the zone when the Issuer does not name a hostedZoneID. Both are
# read-only; the write is the one that needed a fence.
data "aws_iam_policy_document" "cert_manager_dns01" {
  count = var.create_cert_manager_role ? 1 : 0

  statement {
    sid       = "PollChangeStatus"
    actions   = ["route53:GetChange"]
    resources = ["arn:aws:route53:::change/*"]
  }

  statement {
    sid       = "ReadRecordsInAllowedZones"
    actions   = ["route53:ListResourceRecordSets"]
    resources = var.cert_manager_hosted_zone_arns
  }

  statement {
    sid       = "FindZoneByName"
    actions   = ["route53:ListHostedZonesByName"]
    resources = ["*"]
  }

  statement {
    sid       = "WriteChallengeTxtOnly"
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = var.cert_manager_hosted_zone_arns

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "route53:ChangeResourceRecordSetsRecordTypes"
      values   = ["TXT"]
    }
  }
}

resource "aws_iam_policy" "cert_manager_dns01" {
  count = var.create_cert_manager_role ? 1 : 0

  name        = "${module.naming.name}-cert-manager-dns01"
  description = "DNS-01 challenge records only: TXT writes in the named hosted zones, nothing else"
  policy      = data.aws_iam_policy_document.cert_manager_dns01[0].json

  tags = module.naming.tags

  # THE ZONE LIST IS THE OTHER HALF OF THE FENCE, so it is checked at plan time
  # rather than trusted. Restricting the record TYPE while leaving the zone at
  # the variable's wildcard default would let this role plant a TXT in EVERY
  # hosted zone of the account -- a domain-validation or SPF record in a zone
  # that serves someone else's live traffic.
  #
  # The check lives HERE and not in a variable validation for two reasons: a
  # validation cannot see create_cert_manager_role, so it would reject the
  # wildcard default even for the estates that create no role at all; and this
  # resource's count is 1 exactly when the role is created, so the precondition
  # runs precisely in the case that matters.
  lifecycle {
    precondition {
      condition     = length(var.cert_manager_hosted_zone_arns) > 0
      error_message = "create_cert_manager_role is true but cert_manager_hosted_zone_arns is empty. An IAM policy statement with no resources is rejected by AWS mid-apply; name the hosted zone(s) cert-manager may write challenge records into."
    }

    precondition {
      condition     = !anytrue([for arn in var.cert_manager_hosted_zone_arns : endswith(arn, "hostedzone/*")])
      error_message = "cert_manager_hosted_zone_arns still carries the wildcard arn:aws:route53:::hostedzone/* -- every hosted zone in the account. Name the specific zone(s): the record-type condition on this policy stops the role writing an A record, but not a TXT in a zone that serves another estate."
    }
  }
}

module "cert_manager_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.33"
  count   = var.create_cert_manager_role ? 1 : 0

  role_name = "${module.naming.name}-cert-manager"

  # attach_cert_manager_policy stays FALSE (its default). The policy above
  # replaces it; enabling both would attach the unconditioned grant alongside
  # the restricted one, and the widest Allow wins.
  role_policy_arns = {
    dns01 = aws_iam_policy.cert_manager_dns01[0].arn
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["cert-manager:cert-manager"]
    }
  }

  tags = module.naming.tags
}
