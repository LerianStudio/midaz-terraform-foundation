# Backend configuration template
# Copy this file and configure for your environment
terraform {
  backend "s3" {
    bucket  = "<your-terraform-state-bucket>"
    key     = "<your-state-key>/terraform.tfstate"
    region  = "<your-region>"
    encrypt = true
    # profile = "<your-aws-profile>"  # Optional: uncomment if using named profile
  }
}