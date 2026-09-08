################################################################################
# Remote state backend — intentionally EMPTY
#
# The bucket, region, lock table and state key are supplied at init time, never
# committed here. One state file per service per environment:
#
#   terraform init \
#     -backend-config=../../../backend/prd.hcl \
#     -backend-config="key=aws/products/network/route53-delegation/terraform.tfstate"
#
# The relative path is three levels up, not four: this directory is
# examples/aws/products/network/route53-delegation, so ../../../ lands on
# examples/aws, where both backend/ and _modules/ live.
#
# ONE ENVIRONMENT, ONE STATE — and here that is a constraint, not a convenience.
# The state key above carries no environment, and bootstrap puts the environment
# in the bucket name instead (lerian-tfstate-{environment}-{account_id},
# bootstrap/main.tf:124-125). The sibling root vpc-peering-accepter exploits that
# to be applied twice in this account, as `stg` and as `prd`. This root must NOT
# be: it writes NS records into ONE parent zone, so a second state would own the
# same records, and a destroy in either would pull the child zones off the public
# internet while the other state still reported them present. The precondition in
# main.tf refuses any environment but the one the parent zone lives in.
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
