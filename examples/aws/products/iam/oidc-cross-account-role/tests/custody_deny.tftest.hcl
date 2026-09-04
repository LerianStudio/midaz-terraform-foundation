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
# to" is only true if something refuses the plan without it. These seven runs
# are that something: one policy with the real Deny plans clean, and six
# documents that read correct in review fail at the precondition on
# aws_iam_role_policy.this — the Deny deleted, the Deny neutralised by a
# Condition, the Deny scoped to another account, the Deny with no trailing
# wildcard on the ARN, the Deny carrying only two of the eight verbs, and the
# Deny narrowed by a path segment appended after the wildcard.
#
# THE LAST FIVE ARE THE ONES THAT MATTER, because each still looks right: the
# statement is there, the word Deny is there, the custody path is there, and the
# statement denies nothing that can actually happen in this account.
#
# mock_provider: no AWS call, no credential, no state. The precondition reads
# var.policy_json, var.region and the account/partition data sources, and the
# two override_data blocks below pin those, so it is fully decidable offline.
################################################################################

mock_provider "aws" {}

# The guard anchors the custody ARN to the account and partition of the apply.
# Under mock_provider these data sources would otherwise return generated
# values, and every fixture ARN below — which carries the REAL application
# account, as the tfvars does — would fail to match for the wrong reason.
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

run "deny_scoped_to_other_account_refused" {
  command = plan

  variables {
    # The Deny is verbatim — eight verbs, custody path, no Condition — and its
    # ARN names account 111122223333. IAM evaluates it against requests for
    # secrets that do not exist here, so it never matches anything, and the
    # custody path in THIS account stays both writable and readable. A copied
    # tfvars from a different estate is exactly how this arrives.
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
            "Resource": "arn:aws:secretsmanager:sa-east-1:111122223333:secret:tenants/*/*/*/external/*"
          }
        ]
      }
    EOT
  }

  expect_failures = [aws_iam_role_policy.this]
}

run "wildcard_missing_refused" {
  command = plan

  variables {
    # The Deny with its trailing wildcard dropped: the ARN ends at "external/".
    # Secrets Manager appends six random characters to every secret ARN, so this
    # statement matches NO real secret and denies nothing — while looking, path
    # for path, like the document it replaced. The likeliest hand-copy slip on
    # the whole page.
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
            "Resource": "arn:aws:secretsmanager:sa-east-1:862902859103:secret:tenants/*/*/*/external/"
          }
        ]
      }
    EOT
  }

  expect_failures = [aws_iam_role_policy.this]
}

run "partial_verbs_refused" {
  command = plan

  variables {
    # The Deny narrowed to the two verbs the older guard demanded. What is left
    # allowed on the custody ARNs: CreateSecret and UpdateSecret (overwrite the
    # client's Dataprev credential by another door), DeleteSecret/RestoreSecret,
    # and BatchGetSecretValue/DescribeSecret (read and enumerate it). Refusing
    # this is the reason the guard names all eight verbs and not a shape.
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
              "secretsmanager:PutSecretValue",
              "secretsmanager:GetSecretValue"
            ],
            "Resource": "arn:aws:secretsmanager:sa-east-1:862902859103:secret:tenants/*/*/*/external/*"
          }
        ]
      }
    EOT
  }

  expect_failures = [aws_iam_role_policy.this]
}

run "suffix_after_wildcard_refused" {
  command = plan

  variables {
    # The Deny with a path segment appended AFTER the trailing wildcard. It is
    # verbatim on every other axis — eight verbs, this account, this region, no
    # Condition — and it still ends in a `*`, so it survives the "missing
    # wildcard" check above. It denies nothing: IAM reads the whole ARN, and a
    # real custody secret is
    # `tenants/{env}/{org}/{app}/external/{name}-AbCdEf`, which has no
    # `/nothing-real/` segment in it. Narrowing by APPENDING is the lookalike
    # that survives every check that only asks whether the custody path appears
    # somewhere in the string.
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
            "Resource": "arn:aws:secretsmanager:sa-east-1:862902859103:secret:tenants/*/*/*/external/*/nothing-real/*"
          }
        ]
      }
    EOT
  }

  expect_failures = [aws_iam_role_policy.this]
}
