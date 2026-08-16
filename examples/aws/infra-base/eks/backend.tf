# Remote state in S3. Intentionally empty: the configuration is injected at
# init time so the same code serves dev, stg and prd without edits.
#
#   terraform init \
#     -backend-config=../../backend/dev.hcl \
#     -backend-config="key=aws/infra-base/eks/terraform.tfstate"
terraform {
  backend "s3" {}
}
