terraform {
  # 1.9.0, not the 1.5.0 most of this tree carries: variables.tf cross-references
  # var.engine_version and var.major_engine_version from inside a validation block,
  # and referring to another variable there landed in Terraform 1.9. An older CLI
  # fails on an invalid reference instead of saying its version is too old.
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.42.0, < 7.0.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5.1"
    }
  }
}
