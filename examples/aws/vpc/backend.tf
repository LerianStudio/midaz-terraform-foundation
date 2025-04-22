terraform {
  backend "s3" {
    bucket         = "<PUT-YOUR-BUCKET-NAME-HERE>"
    key            = "aws/vpc/terraform.tfstate"
    region         = "<PUT-YOUR-BUCKET-REGION-HERE>"
    encrypt        = true
    dynamodb_table = "<PUT-YOUR-DYNAMODB-LOCK-TABLE-NAME-HERE>" # Optional, for state locking
  }
}
