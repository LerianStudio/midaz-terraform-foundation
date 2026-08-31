# Terraform and provider version constraints for the mongodb-documentdb module.
# Child module: no provider block and no backend here - both belong to the
# root stack that consumes this module.
terraform {
  required_version = ">= 1.5.0"

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
