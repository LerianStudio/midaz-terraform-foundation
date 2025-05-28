# Configure remote state storage in AWS S3
terraform {
  backend "s3" {
    bucket         = "<PUT-YOUR-BUCKET-NAME-HERE>"
    key            = "aws/eks/terraform.tfstate"
    region         = "<PUT-YOUR-BUCKET-REGION-HERE>"
    encrypt        = true
    dynamodb_table = "<PUT-YOUR-DYNAMODB-LOCK-TABLE-NAME-HERE>" # Optional, for state locking
  }
}
