################################################################################
# The two things that are DERIVED here, and are wrong in ways an apply cannot see
#
# Everything else in this root is a literal somebody can read. These two are
# built from inputs, and both fail silently:
#
#   1. THE CHANNEL FOLDERS. go-release chooses the top-level folder from the
#      tag's channel — beta -> development/, rc -> staging/, stable ->
#      production/ — and an s3_uploads entry runs on EVERY tag, not on the
#      channel somebody had in mind. A policy missing a channel applies cleanly,
#      reads correct, and turns the `S3 Upload` job red on the first tag of that
#      channel, which for a repository that cuts a beta per merge is every merge.
#      That is not a hypothetical: an earlier cut of this task's design left
#      development/ out.
#
#   2. THE SUBJECT. `repo:{owner}/{repo}:ref:refs/tags/*` is the whole trust
#      boundary. A subject built one segment wrong does not fail the apply: the
#      role exists, and the pipeline gets AccessDenied on a tag months later.
#
# The runs below pin both against literals, and then prove the two inputs that
# are easy to paste wrong are refused rather than interpolated.
#
# mock_provider: no AWS call, no credential, no state. override_data pins the
# partition the ARNs are built from — without it the mocked value is generated
# and the ARN assertions compare against noise.
################################################################################

mock_provider "aws" {}

override_data {
  target = data.aws_partition.current
  values = {
    partition = "aws"
  }
}

variables {
  region                 = "sa-east-1"
  environment            = "prd"
  github_repository      = "LerianStudio/br-consignado-gw"
  role_name              = "consignado-github-oidc-s3-upload"
  migrations_bucket_name = "tenant-manager-prd-migrations-862902859103"
}

run "every_release_channel_and_nothing_else" {
  command = plan

  # Three, and the count is the assertion that catches a DROPPED channel — the
  # set-comparison below would also catch it, but the count says which failure it
  # is when the message is read at 3am.
  assert {
    condition     = length(output.object_prefix_arns) == 3
    error_message = "The policy does not grant exactly three object prefixes. go-release writes under development/, staging/ and production/ depending on the tag's channel, and every s3_uploads entry runs on every tag: a missing channel makes the release job fail on the first tag of that channel, and an extra prefix widens the role past what any pipeline writes."
  }

  # Read off the document ACTUALLY ATTACHED to the role, not the output. An
  # output is a convenience that a refactor can leave pointing at the old local
  # while the resource takes a new one; the attached policy is the thing that
  # grants.
  assert {
    condition = toset(jsondecode(aws_iam_role_policy.upload.policy).Statement[0].Resource) == toset([
      "arn:aws:s3:::tenant-manager-prd-migrations-862902859103/development/br-consignado-gw/*",
      "arn:aws:s3:::tenant-manager-prd-migrations-862902859103/staging/br-consignado-gw/*",
      "arn:aws:s3:::tenant-manager-prd-migrations-862902859103/production/br-consignado-gw/*",
    ])
    error_message = "The granted object ARNs are not {channel}/{repo}/* over the three channels. The trailing wildcard is mandatory — go-release appends the module and dbType segments (br-consignado-gw/consignado/postgresql/…) — and the repository segment must come from github_repository, so the identity that uploads and the path it may write to cannot drift apart."
  }

  # ONE VERB, and it is not DeleteObject. The tenant manager decides what to run
  # by comparing a tenant's applied migrations against the ones available in the
  # bucket, so removing a .sql a tenant already applied puts a hole in that
  # comparison. A widened action list applies cleanly and is invisible until it
  # is used.
  assert {
    condition = (
      length(jsondecode(aws_iam_role_policy.upload.policy).Statement) == 1 &&
      jsondecode(aws_iam_role_policy.upload.policy).Statement[0].Action == "s3:PutObject" &&
      jsondecode(aws_iam_role_policy.upload.policy).Statement[0].Effect == "Allow"
    )
    error_message = "The inline policy is not exactly one Allow of s3:PutObject. A release pipeline only ever adds files: s3:DeleteObject would let it remove a migration a tenant already applied, and s3:ListBucket belongs to the reader, which is not this identity."
  }

  assert {
    condition     = output.allowed_subject == "repo:LerianStudio/br-consignado-gw:ref:refs/tags/*"
    error_message = "The trust subject is not repo:{owner}/{repo}:ref:refs/tags/*. The wildcard belongs on the TAG NAME and nowhere else: widened to refs/* it admits branch pushes, including a workflow edited in a fork's pull request; narrowed to a literal tag it admits exactly one release and no other."
  }
}

run "owner_without_repository_refused" {
  command = plan

  # An owner alone interpolates into `repo:LerianStudio:ref:refs/tags/*`, a
  # subject no token ever carries — the role would exist and admit nobody — and
  # split()[1] would fail the plan somewhere less legible than here.
  variables {
    github_repository = "LerianStudio"
  }

  expect_failures = [var.github_repository]
}

run "bucket_arn_instead_of_name_refused" {
  command = plan

  # The variable is used to BUILD an ARN. An ARN pasted here produces
  # arn:aws:s3:::arn:aws:s3:::bucket/... — a resource that matches nothing, so
  # the apply succeeds and every upload is denied.
  variables {
    migrations_bucket_name = "arn:aws:s3:::tenant-manager-prd-migrations-862902859103"
  }

  expect_failures = [var.migrations_bucket_name]
}
