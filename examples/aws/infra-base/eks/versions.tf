# Terraform and provider version constraints.
#
# The lower bound below is the repository-wide floor. The EKS module
# (terraform-aws-modules/eks/aws ~> 21.0) raises the effective floor to
# aws >= 6.52 on its own, so `terraform init` resolves a 6.x provider here.
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.42.0, < 7.0.0"
    }
  }
}
