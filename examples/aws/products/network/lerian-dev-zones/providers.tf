################################################################################
# Provider
#
# DECISION: no `default_tags` block, matching every other root in this estate.
# Both resources here tag from module.naming.tags explicitly. default_tags would
# duplicate that set invisibly, make it depend on provider configuration rather
# than on the naming contract every cross-stack tag:Name lookup resolves against,
# and is a known source of perpetual diffs.
#
# var.extra_tags is the extension point: it flows into module.naming and therefore
# onto both the zone and the certificate, visibly and in state.
################################################################################

provider "aws" {
  region = var.region
}
