################################################################################
# products/br-consignado-gw/s3 — immutable custody of averbação artefacts
#
# THIS BUCKET IS THE ONLY WORM STORAGE ON THE ESTATE, and the gateway will not boot
# without it configured correctly. It holds the artefacts of averbação — the act of
# registering a payroll-deducted loan against a worker's margin — which is the
# evidence trail behind money that moves.
#
# THE BOOT-TIME CONTRACT, measured, not assumed. On startup the gateway reads the
# bucket's Object Lock configuration and REFUSES TO START unless it finds a DEFAULT
# RETENTION OF AT LEAST 1827 DAYS, five years
# (lib-commons .../tenant-manager/s3/retained_storage.go:24-25, asserted at
# internal/bootstrap/artifact_storage.go:61). The mode it writes with is pinned to
# COMPLIANCE in the gateway's own code
# (internal/consignado/adapters/s3/retained_artifact_store.go:45).
#
# COMPLIANCE, NOT GOVERNANCE, AND THE DIFFERENCE IS THE WHOLE POINT. Under
# GOVERNANCE a principal holding s3:BypassGovernanceRetention can delete a retained
# object early. Under COMPLIANCE nobody can — not the account root, not AWS
# support, not for any reason, until the retention expires. That is what makes the
# artefact evidence rather than a file.
#
# IT CANNOT BE FIXED AFTER THE FACT. Object Lock is settable ONLY at bucket
# creation. A bucket created without it has to be REPLACED and every object
# re-uploaded — and objects already written under COMPLIANCE cannot be deleted, so
# the old bucket cannot be cleaned up either. Get it right on the first apply.
#
# HOW THE GATEWAY WRITES. Retention rides inline on PutObject as ObjectLockMode +
# ObjectLockRetainUntilDate, with IfNoneMatch "*" so a re-put cannot overwrite. AWS
# evaluates s3:PutObjectRetention on any such write EVEN THOUGH NO API BY THAT NAME
# IS CALLED — _modules/s3-bucket grants it whenever object_lock_enabled is true,
# and s3:BypassGovernanceRetention is deliberately never granted.
#
# The other calls are GetObject, HeadObject, GetObjectLockConfiguration and
# ListObjectVersions. The last one needs s3:ListBucketVersions, which s3:ListBucket
# does NOT cover — a versioned custody bucket is enumerated by version.
#
# NO LIFECYCLE EXPIRY. Every other bucket in this repository tiers and expires; this
# one must not. An expiration rule on a COMPLIANCE-locked object does not delete it,
# it just accumulates failed lifecycle transitions. Retention is the policy here.
#
# Deploy order: infra-base/eks -> this stack, because the OIDC lookup is SINGULAR
# and fails the plan when the cluster does not exist. That is stricter than the
# datastore roots and it is wanted: an IRSA role attached to a provider that is not
# there applies cleanly and produces pods that cannot write custody artefacts.
################################################################################

module "network" {
  source = "../../../_modules/product-network"

  enabled     = false
  environment = var.environment

  eks_cluster_name = var.eks_cluster_name
}

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
