################################################################################
# products/fetcher/s3 — the object storage of fetcher
#
# ONE ROOT STACK PER SERVICE, same as the datastore siblings: one directory, one
# state file (aws/products/fetcher/s3/terraform.tfstate).
#
# THIS ROOT IS SHAPED DIFFERENTLY FROM ITS SIBLINGS, on purpose. Three contract
# points that hold for every datastore root do not hold here, and each one is a
# property of S3 rather than an omission:
#
#   1. There is NO var.mode. _modules/s3-bucket has no `mode` input: a bucket
#      costs nothing when empty and its contents are the private data of exactly
#      one product, so there is no shared bucket tier to resolve. A `mode`
#      variable here would only ever accept "dedicated". The `mode` OUTPUT is
#      still published as a constant so `terraform output mode` keeps working
#      uniformly across every root of this product.
#
#   2. There is NO ingress, no security group and no subnet placement. S3 is a
#      regional endpoint reached over the AWS API, not a host inside the VPC, so
#      allowed_cidr_blocks / allowed_security_group_ids have nothing to act on.
#      Access is granted by IAM (IRSA), which is what this root wires instead.
#
#   3. The seven uniform outputs (endpoint, port, secret_arn, ...) are NOT
#      implemented. See outputs.tf.
#
# What it does share with the siblings: the naming contract (through the module),
# the empty S3 backend, the provider block, and the derived EKS cluster name.
#
# Deploy order: infra-base/eks -> this stack, when IRSA is enabled. That is a
# HARDER prerequisite than the datastore roots have — they tolerate a missing
# cluster through the plural security group lookup, while the OIDC provider
# lookup below is singular and fails the plan. See var.irsa_enabled.
################################################################################

################################################################################
# Network resolution — _modules/product-network with enabled = false
#
# Called with enabled = false, which performs NO AWS lookup at all: no VPC, no
# subnets, no security groups. The only thing consumed from it is
# eks_cluster_name, a pure string derivation from var.environment that is valid
# whether or not anything exists yet.
#
# Why call the module for one string instead of deriving it inline: the two
# cross-stack names are the module's contract, and a literal
# "lerian-${var.environment}-eks" here would be the seventieth copy of a
# derivation that has exactly one owner. If infra-base ever renames the cluster,
# the module changes and this root follows.
################################################################################

module "network" {
  source = "../../../_modules/product-network"

  enabled     = false
  environment = var.environment

  eks_cluster_name = var.eks_cluster_name
}

################################################################################
# IRSA — resolving the cluster OIDC provider ARN
#
# _modules/s3-bucket needs oidc_provider_arn + service_account to create the IAM
# role a pod assumes. infra-base/eks exports oidc_provider_arn, but this root
# does not read that state, and three ways to get the value were considered:
#
#   a) terraform_remote_state on infra-base/eks — REJECTED. It couples a product
#      stack to the foundation's state file layout AND to its backend
#      credentials, which is exactly the coupling _modules/mongodb-documentdb
#      rejected when it chose a data source over remote state for shared mode.
#
#   b) an explicit variable the operator copies out of `terraform output` —
#      kept, as var.oidc_provider_arn, but not as the default path: it is a
#      hand-copied 100-character ARN that silently rots when the cluster is
#      replaced.
#
#   c) DERIVE IT, the way every other cross-stack reference in this repository
#      is derived: from the cluster name, by data source. This is the default.
#
# The chain is name -> cluster -> issuer URL -> OIDC provider ARN. Both data
# sources are SINGULAR and fail the plan when the cluster does not exist, which
# is the wanted behaviour: an IRSA role attached to a provider that is not there
# would apply cleanly and produce pods that cannot reach the bucket.
#
# Set irsa_enabled = false to skip the chain entirely and emit IAM policies only,
# for an EKS stack that manages its own roles.
################################################################################

locals {
  lookup_oidc_provider = var.irsa_enabled && var.oidc_provider_arn == ""

  oidc_provider_arn = var.irsa_enabled ? (
    var.oidc_provider_arn != "" ? var.oidc_provider_arn : one(data.aws_iam_openid_connect_provider.cluster[*].arn)
  ) : ""

  service_account = var.irsa_enabled ? var.service_account : ""
}

data "aws_eks_cluster" "cluster" {
  count = local.lookup_oidc_provider ? 1 : 0

  name = module.network.eks_cluster_name
}

data "aws_iam_openid_connect_provider" "cluster" {
  count = local.lookup_oidc_provider ? 1 : 0

  url = data.aws_eks_cluster.cluster[0].identity[0].oidc[0].issuer
}

################################################################################
# Object storage — fetcher-{environment}-external-data-{account_id}
#
# The account id suffix is the documented naming exception: S3 bucket names are
# globally unique across every AWS account, so fetcher-{env}-external-data alone
# would collide with any other AWS customer that picked the same words. The
# prefix still comes from the naming module, inside the s3-bucket module.
#
# external-data holds the raw output of extraction jobs. It is the only bucket
# this product needs, and the shortest-lived of the three: extraction output is
# reprocessable from the source system, so the lifecycle expires it rather than
# archiving it.
################################################################################

module "storage" {
  source = "../../../_modules/s3-bucket"

  product     = var.product
  environment = var.environment
  extra_tags  = var.extra_tags

  buckets = var.buckets

  transition_ia_storage_class      = var.transition_ia_storage_class
  transition_glacier_storage_class = var.transition_glacier_storage_class
  require_latest_tls_policy        = var.require_latest_tls_policy

  oidc_provider_arn = local.oidc_provider_arn
  service_account   = local.service_account
}
