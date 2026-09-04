################################################################################
# The issuer URL is a TRUST DECISION, and a prefix is not one
#
# This value does not merely get recorded. aws_iam_openid_connect_provider copies
# the issuer into THIS account as an identity provider, and the role's trust
# policy then accepts any token that issuer signs, for the ServiceAccount subject
# it names. An earlier cut of the variable checked
# startswith(url, "https://oidc.eks.") — which is a check on a prefix anybody can
# register underneath: https://oidc.eks.attacker.example/id/... satisfies it, and
# a host somebody else controls becomes a trusted issuer of tokens for a role
# that reaches every tenant secret in the account.
#
# The validation now requires the whole shape AWS actually emits — the
# amazonaws.com (or amazonaws.com.cn) hostname and the /id/{32 uppercase hex}
# path an EKS cluster's OIDC endpoint has. These two runs are the proof that the
# hostname half is load-bearing: same well-formed /id/ segment on both, and only
# the AWS-owned host survives.
#
# mock_provider: no AWS call, no credential, no state. The two override_data
# blocks pin the account and partition the ARNs are built from — see
# custody_deny.tftest.hcl, which explains the same setup at length.
################################################################################

mock_provider "aws" {}

override_data {
  target = data.aws_caller_identity.current
  values = {
    account_id = "862902859103"
  }
}

override_data {
  target = data.aws_partition.current
  values = {
    partition = "aws"
  }
}

variables {
  region                  = "sa-east-1"
  environment             = "prd"
  oidc_issuer_url         = "https://oidc.eks.sa-east-1.amazonaws.com/id/0123456789ABCDEF0123456789ABCDEF"
  sa_subject              = "platform:tenant-manager"
  role_name               = "consignado-tenant-manager-cross-account"
  additional_policy_names = []

  policy_json = <<-EOT
    {
      "Version": "2012-10-17",
      "Statement": [
        {
          "Sid": "ListSecretsAccountWide",
          "Effect": "Allow",
          "Action": "secretsmanager:ListSecrets",
          "Resource": "*"
        }
      ]
    }
  EOT
}

run "real_eks_issuer_accepted" {
  command = plan
}

run "non_aws_host_refused" {
  command = plan

  # The whole point: a path that looks exactly like an EKS issuer id, on a host
  # that is not AWS. Registering this would put a stranger's signing key in this
  # account's trust chain.
  variables {
    oidc_issuer_url = "https://oidc.eks.attacker.example/id/0123456789ABCDEF0123456789ABCDEF"
  }

  expect_failures = [var.oidc_issuer_url]
}
