################################################################################
# Remote state backend — intentionally EMPTY
#
# The bucket, region, lock table and state key are supplied at init time, never
# committed here. One state file per service per environment:
#
#   terraform init \
#     -backend-config=../../../backend/prd.hcl \
#     -backend-config="key=aws/products/network/vpc-peering-accepter/terraform.tfstate"
#
# The relative path is three levels up, not four: this directory is
# examples/aws/products/network/vpc-peering-accepter, so ../../../ lands on
# examples/aws, where both backend/ and _modules/ live.
#
# ONE DIRECTORY, TWO STATES. This root is applied TWICE in the SAME AWS account —
# once as `stg`, once as `prd` — and the state key above carries no environment
# in it. The two applies do not collide because the bucket does: bootstrap names
# it lerian-tfstate-{environment}-{account_id} and the lock table
# lerian-tfstate-lock-{environment} (bootstrap/main.tf:124-125), so the
# environment is baked into the -backend-config file, not into the key.
#
# That is why every input here is SINGULAR — one pcx_id, one peer_cidr. Each
# environment accepts its own peering, in its own state. A map of peerings in one
# state would put staging and production routing in a single blast radius, which
# is exactly the coupling the two stacks exist to avoid.
#
# Do NOT add placeholder values (<PUT-YOUR-BUCKET-NAME-HERE> and friends). The
# placeholder check in lerian-infra greps for "<...>" in backend files and
# aborts the run when it finds one.
################################################################################

terraform {
  backend "s3" {}
}
