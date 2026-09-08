################################################################################
# Provider
#
# DECISION: no `default_tags` block, the same decision documented in
# infra-base/vpc/providers.tf and products/lerian-platform/dns/providers.tf.
# Every resource this root creates is tagged explicitly from module.naming.tags,
# which is the naming contract every cross-stack `tag:Name` lookup in this
# repository resolves against. default_tags would duplicate that set invisibly,
# make it depend on provider configuration rather than on the contract, and is a
# known source of perpetual diffs.
#
# var.extra_tags is the extension point: it flows into module.naming and
# therefore into every resource, visibly and in state.
################################################################################

provider "aws" {
  region = var.region
}
