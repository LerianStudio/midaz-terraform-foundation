################################################################################
# Provider
#
# DECISION: no `default_tags` block, for the same reason documented in
# infra-base/vpc/providers.tf. This root stack creates no AWS resource of its
# own — everything is created inside the datastore module, which tags from
# module.naming.tags explicitly. default_tags would duplicate that set
# invisibly, make it depend on provider configuration rather than on the naming
# contract every cross-stack tag:Name lookup resolves against, and is a known
# source of perpetual diffs on terraform-aws-modules resources that compute
# their own Name tag.
#
# var.extra_tags is the extension point: it flows into the module, into
# module.naming, and therefore into every resource, visibly and in state.
################################################################################

provider "aws" {
  region = var.region
}
