################################################################################
# BOTH borrowed policies, or the control plane is half-configured
#
# products/tenant-manager/s3 creates no role. It emits two managed policies for
# whichever role the ServiceAccount annotates — one for the migrations bucket,
# one for the Casdoor templates — and a ServiceAccount carries exactly one
# role-arn, so this role borrows both or the estate loses one of them silently.
# Losing the casdoor-templates half is the expensive one: tenant onboarding fails
# at the template fetch, long after a clean apply.
#
# So the list is not "whatever names somebody wrote". It is exactly two, one of
# each suffix. The runs below are the ways a plausible list can be wrong:
#
#   []                        nothing borrowed        -> refused
#   migrations only           the half that applies   -> refused
#   migrations twice          two entries, one concern-> refused
#   the two plus a third      more than the contract  -> refused
#   an ARN                    not a name at all       -> refused
#
# THE ENVIRONMENT SEGMENT IS FREE and stays free: that sibling root names its
# policies after its own environment, so pinning "prd" here would refuse a
# correct list anywhere else. The suffixes are what is pinned — they are that
# root's contract inside this same repository.
#
# The variable also has no default, which is not visible in these runs but in
# every OTHER fixture of this root: they all have to state what the role
# borrows.
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

  # The measured content for the control plane.
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

run "the_two_prd_policies_accepted" {
  command = plan
}

run "another_environments_names_accepted" {
  command = plan

  # THE POINT OF THE FREE SEGMENT, asserted rather than described. Every other
  # run here uses prd names, so a regex tightened to tenant-manager-prd-* would
  # pass all of them and refuse a correct list in staging. This run is what
  # fails if somebody freezes the environment label.
  variables {
    additional_policy_names = [
      "tenant-manager-stg-migrations-s3-access",
      "tenant-manager-stg-casdoor-templates-s3-access",
    ]
  }
}

run "an_empty_list_refused" {
  command = plan

  # Legal while the variable had a default of []. It means a role that reaches
  # neither bucket, which applies cleanly and fails at the first onboarding.
  variables {
    additional_policy_names = []
  }

  expect_failures = [var.additional_policy_names]
}

run "only_the_migrations_policy_refused" {
  command = plan

  # The realistic half: migrations is the one somebody remembers, because a
  # missing migration fails loudly and a missing template does not.
  variables {
    additional_policy_names = ["tenant-manager-prd-migrations-s3-access"]
  }

  expect_failures = [var.additional_policy_names]
}

run "the_migrations_policy_twice_refused" {
  command = plan

  # Two entries and one concern — what a copy-and-paste of the first line looks
  # like. A count of 2 is not the property that matters; one of each is.
  variables {
    additional_policy_names = [
      "tenant-manager-prd-migrations-s3-access",
      "tenant-manager-prd-migrations-s3-access",
    ]
  }

  expect_failures = [var.additional_policy_names]
}

run "a_third_policy_refused" {
  command = plan

  # Both required policies are present, plus something else. This role's reach
  # is the widest on the estate; a policy that arrives by being appended here is
  # a grant nobody reviewed as one.
  variables {
    additional_policy_names = [
      "tenant-manager-prd-migrations-s3-access",
      "tenant-manager-prd-casdoor-templates-s3-access",
      "tenant-manager-prd-something-else-s3-access",
    ]
  }

  expect_failures = [var.additional_policy_names]
}

run "an_arn_instead_of_a_name_refused" {
  command = plan

  # main.tf builds the ARN around each entry, so an ARN here becomes an ARN
  # inside an ARN and fails at apply with NoSuchEntity.
  variables {
    additional_policy_names = [
      "arn:aws:iam::862902859103:policy/tenant-manager-prd-migrations-s3-access",
      "arn:aws:iam::862902859103:policy/tenant-manager-prd-casdoor-templates-s3-access",
    ]
  }

  expect_failures = [var.additional_policy_names]
}
