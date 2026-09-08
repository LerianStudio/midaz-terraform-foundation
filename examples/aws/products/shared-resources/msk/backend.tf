################################################################################
# Remote state backend — intentionally EMPTY
#
# The bucket, region, lock table and state key are supplied at init time, never
# committed here. ONE STATE FILE PER SERVICE per environment — this tier used to
# be a single infra-base/shared-services state holding all five datastores:
#
#   terraform init \
#     -backend-config=../../../backend/dev.hcl \
#     -backend-config="key=aws/products/shared-resources/msk/terraform.tfstate"
#
# The relative path is three levels up, not four: this directory is
# examples/aws/products/shared-resources/msk, so ../../../ lands on
# examples/aws, where both backend/ and _modules/ live.
#
# Do NOT commit placeholder values here, of the PUT-YOUR-BUCKET-NAME-HERE kind.
# Nothing in this tree would catch them: the lerian-infra placeholder check reads
# the env tfvars, and the only check that greps backend.tf is deploy-legacy.sh,
# which covers the legacy providers and says so in its own comment. A placeholder
# committed here reaches an init unnoticed.
################################################################################

terraform {
  backend "s3" {}
}
