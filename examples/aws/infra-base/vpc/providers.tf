################################################################################
# Provider
#
# DECISION: no `default_tags` block. Every resource in this stack tags itself
# from module.naming.tags explicitly, so default_tags would only duplicate what
# is already there, and it would do so invisibly:
#
#   1. Tags injected by default_tags do not appear in the resource bodies, so a
#      reviewer reading main.tf cannot tell what a resource is tagged with, and
#      `terraform plan` attributes them to the provider rather than the module.
#   2. The tag set would then depend on provider configuration instead of the
#      naming contract, which is what every cross-stack tag:Name lookup in this
#      repository resolves against. A stack initialised with a different provider
#      block would produce differently tagged resources from identical HCL.
#   3. terraform-aws-modules resources that compute their own `Name` tag are a
#      long-standing source of perpetual diffs when the same key also arrives via
#      default_tags.
#
# The extension point for client-specific tags is var.extra_tags, which flows
# into module.naming and therefore into every resource, in state, visibly.
################################################################################

provider "aws" {
  region = var.region
}
