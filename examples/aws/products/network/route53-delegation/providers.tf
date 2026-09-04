################################################################################
# Provider
#
# DECISION: no `default_tags` block, and no var.extra_tags either — the same
# decision as infra-base/vpc/providers.tf and products/lerian-platform/dns
# /providers.tf, reached for a blunter reason here.
#
# THIS ROOT CREATES NOTHING TAGGABLE. A Route53 record is not a taggable AWS
# resource: it has no ARN and no tag set, and it is the only resource kind in
# this directory. default_tags would apply to nothing, and an extra_tags variable
# would have nowhere to land — an input accepted and silently discarded is worse
# than an input that does not exist, because a reviewer reads it as ownership
# metadata that made it into AWS.
#
# Ownership and cost attribution for these records live on the zones themselves,
# which products/lerian-platform/dns tags from module.naming in both accounts.
#
# Route53 is a GLOBAL service. var.region only selects the endpoint the API call
# goes through; it does not place the records anywhere.
################################################################################

provider "aws" {
  region = var.region
}
