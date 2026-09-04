################################################################################
# The custody Deny is an invariant, and this is what holds it
#
# tenants/{env}/{org}/{app}/external/ holds a client's Dataprev credential. The
# gateway pays real cost for that path to be immutable — a variable validation
# refuses it PutSecretValue, so rotation writes a NEW version and the audit trail
# cannot be rewritten. That property is worth exactly nothing if the control
# plane next door can rewrite or read the same ARNs.
#
# So the policy this root attaches has to carry an UNCONDITIONAL Deny, and "has
# to" is only true if something refuses the plan without it. These three runs are
# that something: one policy with the Deny plans clean, the same policy without
# it fails at the precondition on aws_iam_role_policy.this, and the same policy
# with the Deny narrowed by a Condition fails there too.
#
# The third run is the one that matters most, because it is the one that still
# looks right in review: the statement is there, the eight verbs are there, the
# custody ARN is there, and the Deny applies to nobody.
#
# mock_provider: no AWS call, no credential, no state. The precondition reads
# var.policy_json and nothing else, so it is fully decidable offline.
################################################################################

mock_provider "aws" {}

variables {
  region          = "sa-east-1"
  environment     = "prd"
  oidc_issuer_url = "https://oidc.eks.sa-east-1.amazonaws.com/id/EXAMPLE0123456789ABCDEF0123456789"
  sa_subject      = "platform:tenant-manager"
  role_name       = "consignado-tenant-manager-cross-account"
}

run "deny_present" {
  command = plan

  variables {
    # Minimal shape of the real document: the wide Allow over tenants/, and the
    # hole carved out of it. Not the full transcription — that lives in the
    # tfvars; this fixture only has to exercise the guard.
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
            "Sid": "DenyScopedSecretPaths",
            "Effect": "Deny",
            "Action": [
              "secretsmanager:CreateSecret",
              "secretsmanager:PutSecretValue",
              "secretsmanager:UpdateSecret",
              "secretsmanager:RestoreSecret",
              "secretsmanager:DeleteSecret",
              "secretsmanager:GetSecretValue",
              "secretsmanager:BatchGetSecretValue",
              "secretsmanager:DescribeSecret"
            ],
            "Resource": "arn:aws:secretsmanager:sa-east-1:862902859103:secret:tenants/*/*/*/external/*"
          }
        ]
      }
    EOT
  }
}

run "deny_missing" {
  command = plan

  variables {
    # The same document with the Deny statement deleted. This is the realistic
    # accident: somebody rewrites the tfvars, keeps the Allow that makes the
    # service work, and drops the statement that makes nothing work differently
    # today. The apply must not be reachable.
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
          }
        ]
      }
    EOT
  }

  expect_failures = [aws_iam_role_policy.this]
}

run "conditioned_deny_refused" {
  command = plan

  variables {
    # The Deny is back, verbatim — and neutralised by a Condition that no request
    # ever satisfies. AWS evaluates a Deny only when its Condition matches, so
    # this document grants the control plane exactly the rewrite and the read the
    # custody path exists to refuse, while reading, statement for statement and
    # verb for verb, like the document it replaced.
    #
    # NotAction and NotResource are the same trick with different spelling
    # (deny everything EXCEPT these verbs / EXCEPT this ARN); the guard refuses
    # all three by demanding their absence.
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
            "Sid": "DenyScopedSecretPaths",
            "Effect": "Deny",
            "Action": [
              "secretsmanager:CreateSecret",
              "secretsmanager:PutSecretValue",
              "secretsmanager:UpdateSecret",
              "secretsmanager:RestoreSecret",
              "secretsmanager:DeleteSecret",
              "secretsmanager:GetSecretValue",
              "secretsmanager:BatchGetSecretValue",
              "secretsmanager:DescribeSecret"
            ],
            "Resource": "arn:aws:secretsmanager:sa-east-1:862902859103:secret:tenants/*/*/*/external/*",
            "Condition": {
              "StringEquals": {
                "aws:PrincipalTag/never": "matches"
              }
            }
          }
        ]
      }
    EOT
  }

  expect_failures = [aws_iam_role_policy.this]
}
