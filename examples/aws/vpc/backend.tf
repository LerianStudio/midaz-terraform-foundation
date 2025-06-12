terraform {
  backend "s3" {
    bucket         = "terraform-midaz-state"
    key            = "aws/vpc/terraform.tfstate"
    region         = "us-east-2"
    encrypt        = true
    # dynamodb_table = "<PUT-YOUR-DYNAMODB-LOCK-TABLE-NAME-HERE>" # Optional, for state locking
  }
}
