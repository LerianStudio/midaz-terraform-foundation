################################################################################
# The borrowed policies are NAMES, and the name is half an ARN
#
# main.tf builds arn:{partition}:iam::{this account}:policy/{name} from every
# entry of additional_policy_names, so an entry is a name or it is nothing: an
# ARN pasted in produces an ARN inside an ARN, and a path-qualified string
# produces a policy path this estate does not use. Both fail at apply with
# NoSuchEntity, naming something that cannot be looked up.
#
# The variable also lost its default in the same change. That is not visible in
# these runs but in every OTHER fixture of this root: they all have to state what
# the role borrows, because omitting the input is now an error rather than an
# empty list. "The control plane needs both S3 policies" and "somebody forgot to
# say" used to be the same tfvars.
#
# mock_provider: no AWS call, no credential, no state — see
# custody_deny.tftest.hcl, which explains the setup at length.
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
  region          = "sa-east-1"
  environment     = "prd"
  oidc_issuer_url = "https://oidc.eks.sa-east-1.amazonaws.com/id/0123456789ABCDEF0123456789ABCDEF"
  sa_subject      = "platform:tenant-manager"
  role_name       = "consignado-tenant-manager-cross-account"

  # The measured content for the control plane: the two policies
  # products/tenant-manager/s3 emits for a role to borrow.
  additional_policy_names = [
    "tenant-manager-prd-migrations-s3-access",
    "tenant-manager-prd-casdoor-templates-s3-access",
  ]

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

run "the_two_tenant_manager_policies_accepted" {
  command = plan
}

run "an_arn_instead_of_a_name_refused" {
  command = plan

  variables {
    additional_policy_names = [
      "arn:aws:iam::862902859103:policy/tenant-manager-prd-migrations-s3-access",
    ]
  }

  expect_failures = [var.additional_policy_names]
}
