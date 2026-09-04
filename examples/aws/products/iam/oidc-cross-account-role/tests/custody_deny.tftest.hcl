################################################################################
# The custody Deny is an invariant, and this root BUILDS it
#
# tenants/{env}/{org}/{app}/external/ holds a client's Dataprev credential. The
# gateway pays real cost for that path to be immutable — a variable validation
# refuses it PutSecretValue, so rotation writes a NEW version and the audit trail
# cannot be rewritten. That property is worth exactly nothing if the control
# plane next door can rewrite or read the same ARNs.
#
# An earlier cut of this root DEMANDED the statement from policy_json and refused
# the plan without it. Recognising a Deny turned out to be a hunt for lookalikes
# — wrong account, missing trailing wildcard, a segment appended after it, verbs
# dropped, the whole statement neutralised by a Condition — with one more found
# every review round. The root now appends the statement itself, so the invariant
# holds by construction and this file only has to prove the construction.
#
# ONE RUN, and it feeds a document with NO Deny in it at all: the Allow half of
# the real transcription and nothing else. If the rendered policy still carries
# exactly one Deny, with the eight measured verbs and the custody ARN of this
# account, then no tfvars can produce a role without it.
#
# mock_provider: no AWS call, no credential, no state. The two override_data
# blocks pin the account and partition the ARN is built from, which under a mock
# provider would otherwise be generated values.
#
# terraform test needs Terraform >= 1.7 (mock_provider). The root's own floor
# stays required_version >= 1.5.0 — the floor is what the roots APPLY under, and
# this file is a local proof, not a step of the foundation's CI.
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
  oidc_issuer_url = "https://oidc.eks.sa-east-1.amazonaws.com/id/EXAMPLE0123456789ABCDEF0123456789"
  sa_subject      = "platform:tenant-manager"
  role_name       = "consignado-tenant-manager-cross-account"

  # The transcription's Allow half, with the Deny deliberately absent. This is
  # the realistic accident the old guard existed to catch: somebody rewrites the
  # tfvars, keeps what makes the service work, and drops the statement that makes
  # nothing work differently today.
  policy_json = <<-EOT
    {
      "Version": "2012-10-17",
      "Statement": [
        {
          "Sid": "ScopedSecretAccess",
          "Effect": "Allow",
          "Action": [
            "secretsmanager:GetSecretValue",
            "secretsmanager:DescribeSecret",
            "secretsmanager:CreateSecret",
            "secretsmanager:PutSecretValue",
            "secretsmanager:RestoreSecret",
            "secretsmanager:DeleteSecret"
          ],
          "Resource": [
            "arn:aws:secretsmanager:sa-east-1:862902859103:secret:tenants/*",
            "arn:aws:secretsmanager:sa-east-1:862902859103:secret:clusters/*"
          ]
        },
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

run "root_builds_the_custody_deny" {
  command = plan

  # Exactly one — not "at least one". Two Deny statements would mean the root is
  # appending on top of a tfvars that already carries one, which is legal but is
  # not what this estate's transcription does, and the count is how that shows up.
  assert {
    condition = length([
      for s in jsondecode(aws_iam_role_policy.this.policy).Statement : s
      if try(s.Effect, "") == "Deny"
    ]) == 1
    error_message = "The attached policy carries no custody Deny, or carries more than one. The root appends exactly one Deny statement to whatever policy_json holds; a count other than 1 means the append is broken or the tfvars now ships a Deny of its own."
  }

  assert {
    condition = one([
      for s in jsondecode(aws_iam_role_policy.this.policy).Statement : s
      if try(s.Effect, "") == "Deny"
    ]).Resource == "arn:aws:secretsmanager:sa-east-1:862902859103:secret:tenants/*/*/*/external/*"
    error_message = "The custody Deny does not name the custody path of THIS account and region, ending in its trailing wildcard. An ARN scoped elsewhere, or one ending at external/ with no wildcard, denies nothing here."
  }

  assert {
    condition = toset(one([
      for s in jsondecode(aws_iam_role_policy.this.policy).Statement : s
      if try(s.Effect, "") == "Deny"
      ]).Action) == toset([
      "secretsmanager:CreateSecret",
      "secretsmanager:PutSecretValue",
      "secretsmanager:UpdateSecret",
      "secretsmanager:RestoreSecret",
      "secretsmanager:DeleteSecret",
      "secretsmanager:GetSecretValue",
      "secretsmanager:BatchGetSecretValue",
      "secretsmanager:DescribeSecret",
    ])
    error_message = "The custody Deny does not carry the eight measured deny_actions of products/tenant-manager/secrets. Put+Get alone still leaves the credential overwritable (CreateSecret/UpdateSecret) and enumerable (BatchGetSecretValue/DescribeSecret)."
  }
}
