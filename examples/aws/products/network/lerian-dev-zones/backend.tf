################################################################################
# Remote state backend — intentionally EMPTY
#
# The bucket, region, lock table and state key are supplied at init time, never
# committed here. One state file per zone, because the three zones of this scheme
# live in two accounts and three Terraform environments:
#
#   terraform init \
#     -backend-config=../../../backend/prd.hcl \
#     -backend-config="key=aws/products/network/lerian-dev-zones/terraform.tfstate"
#
# The relative path is three levels up, not four: this directory is
# examples/aws/products/network/lerian-dev-zones, so ../../../ lands on
# examples/aws, where both backend/ and _modules/ live.
#
# The key carries no environment because the backend bucket does: it is
# lerian-tfstate-{environment}-{account_id}, so the same key in two backends is
# two states. That is what keeps prd.lerian.dev and stg.lerian.dev — same account,
# same key — from sharing one state file.
#
# Do NOT commit placeholder values here, of the PUT-YOUR-BUCKET-NAME-HERE kind.
# Nothing in this tree would catch them: the lerian-infra placeholder check reads
# the env tfvars, and the only check that greps backend.tf is deploy-legacy.sh,
# which covers the legacy providers and says so in its own comment.
################################################################################

terraform {
  backend "s3" {}
}
