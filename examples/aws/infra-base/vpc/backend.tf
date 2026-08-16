################################################################################
# Remote state backend — intentionally EMPTY
#
# The bucket, region, lock table and state key are supplied at init time, never
# committed here. One state file per environment, all of them segregated by the
# bucket that examples/aws/bootstrap created for that environment:
#
#   terraform init \
#     -backend-config=../../backend/dev.hcl \
#     -backend-config="key=aws/infra-base/vpc/terraform.tfstate"
#
# Do NOT add placeholder values (<PUT-YOUR-BUCKET-NAME-HERE> and friends). The
# placeholder check in deploy.sh greps for "<...>" in backend files and aborts
# the deployment when it finds one.
################################################################################

terraform {
  backend "s3" {}
}
