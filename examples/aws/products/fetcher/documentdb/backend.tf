################################################################################
# Remote state backend — intentionally EMPTY
#
# The bucket, region, lock table and state key are supplied at init time, never
# committed here. One state file per service per environment:
#
#   terraform init \
#     -backend-config=../../../backend/dev.hcl \
#     -backend-config="key=aws/products/fetcher/documentdb/terraform.tfstate"
#
# The relative path is three levels up, not four: this directory is
# examples/aws/products/fetcher/documentdb, so ../../../ lands on examples/aws,
# where both backend/ and _modules/ live.
#
# Do NOT add placeholder values (<PUT-YOUR-BUCKET-NAME-HERE> and friends). The
# placeholder check in deploy.sh greps for "<...>" in backend files and aborts
# the deployment when it finds one.
################################################################################

terraform {
  backend "s3" {}
}
