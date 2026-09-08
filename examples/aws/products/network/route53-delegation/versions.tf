terraform {
  # 1.7.0, not the 1.5.0 most of this tree carries: tests/ here uses mock_provider
  # and/or override_data, both 1.7 blocks, and `terraform validate` PARSES
  # tests/*.tftest.hcl rather than skipping them. An older CLI fails on an
  # unsupported block instead of saying its version is too old.
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.42.0, < 7.0.0"
    }
  }
}
