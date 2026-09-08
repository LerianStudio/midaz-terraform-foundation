################################################################################
# Provider
#
# DECISION: no `default_tags` block, the same decision documented in
# infra-base/vpc/providers.tf and products/lerian-platform/dns/providers.tf.
# Every resource this root creates is tagged explicitly from module.naming.tags.
# default_tags would duplicate that set invisibly and make it depend on provider
# configuration rather than on the naming contract.
#
# ONE PROVIDER, ONE ACCOUNT — and that is the whole point of this root. The
# cross-account part of a cross-account role is not a second provider: the role,
# and the copy of the peer cluster's OIDC provider that lets it be assumed, both
# live in the account that owns the resources being reached. Nothing here
# authenticates to the control-plane account, and the account guard in
# lerian-infra has no bypass to allow it.
################################################################################

provider "aws" {
  region = var.region
}
