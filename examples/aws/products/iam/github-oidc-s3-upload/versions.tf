terraform {
  # 1.7.0, not the 1.5.0 the rest of this tree carries. tests/reach_and_subject
  # .tftest.hcl uses mock_provider and override_data, both introduced in 1.7 — and
  # `terraform validate` PARSES tests/*.tftest.hcl, it does not skip them. Measured:
  # dropping an unparseable line into a tests/ file makes plain `validate` fail on
  # it. That is the CI step ("Terraform Init and Validate" runs validate on every
  # directory holding a versions.tf), so the test files are inside the CI parse
  # scope, and required_version is what refuses a CLI too old to read them — with
  # "Unsupported Terraform Core version" instead of a syntax error in a block the
  # runner has never heard of.
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.42.0, < 7.0.0"
    }
  }
}
