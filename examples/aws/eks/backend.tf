# Configure remote state storage in AWS S3
terraform {
  backend "s3" {
    bucket         = "terraform-midaz-state"
    key            = "aws/eks/terraform.tfstate"
    region         = "us-east-2"
    encrypt        = true
    # dynamodb_table = "<PUT-YOUR-DYNAMODB-LOCK-TABLE-NAME-HERE>" # Optional, for state locking
  }
}

