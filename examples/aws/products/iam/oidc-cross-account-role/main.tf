################################################################################
# products/iam/oidc-cross-account-role — the identity the control plane uses to
# provision in the application account
#
# tenant-manager runs in the control-plane account (Terraform environment `dev`)
# and provisions the datastores, tenants and secrets that live in the application
# account (`stg` and `prd`). Its ServiceAccount carries exactly one
# eks.amazonaws.com/role-arn annotation, and the role that annotation names lives
# HERE, next to the resources it touches — not next to the pod that assumes it.
#
# That is the whole design, and it has three parts:
#
#   1. a copy of the control-plane cluster's OIDC issuer, registered as an
#      identity provider in THIS account, so a token minted over there is a
#      principal this account can recognise at all;
#   2. a trust policy pinning one ServiceAccount (`:sub`) and one audience
#      (`:aud`), so exactly one workload in that cluster can assume the role;
#   3. the grants themselves, transcribed from the in-account role this one
#      replaces.
#
# ONE ROLE FOR BOTH STACKS. Staging and production share this AWS account, so one
# role reaches both — applied once, as environment `prd`. The isolation between
# the stacks is in the Secrets Manager path grammar the policy scopes to
# (tenants/staging/... vs tenants/production/...), not in a second role: two
# roles with the same trust and the same reach would be two things to keep equal,
# which is one more than can be kept equal.
#
# WHY IT LIVES UNDER products/ WHEN IT IS NOT A PRODUCT. lerian-infra discovers
# roots by walking products/*/* and nothing else, and its infra-base stage is
# hardcoded to exactly vpc and eks (pkg/infra/discover.go:36-78, :128-153). A
# root outside that shape has no target, no ordering, no state key and no account
# guard. Precedent: products/lerian-platform/dns.
#
# Deploy order: infra-base/eks (over there, for the issuer URL) ->
# products/tenant-manager/s3 (here, for the borrowed policies) -> this root.
################################################################################

module "naming" {
  source = "../../../_modules/naming"

  product     = "tenant-manager"
  environment = var.environment
  component   = "cross-account"
  extra_tags  = var.extra_tags
}

data "aws_caller_identity" "current" {}

# Partition rather than a literal "aws": the same ARNs have to render correctly in
# GovCloud and China, where the partition is aws-us-gov / aws-cn.
data "aws_partition" "current" {}

locals {
  # https://oidc.eks.sa-east-1.amazonaws.com/id/ABC -> oidc.eks.sa-east-1.amazonaws.com/id/ABC
  #
  # The condition keys of a web-identity trust policy are named after the issuer
  # WITHOUT the scheme. Leaving "https://" in place produces a condition on a key
  # no token ever carries, and IAM evaluates a StringEquals on an absent key as
  # FALSE — so the trust policy would admit NOBODY and every AssumeRoleWithWebIdentity
  # would fail closed. The apply still succeeds, and the failure surfaces later as
  # the pod getting AccessDenied on every call. var.oidc_issuer_url is validated to
  # start with the scheme, so this trim always has something to remove.
  oidc_host = trimprefix(var.oidc_issuer_url, "https://")

  service_account_namespace = split(":", var.sa_subject)[0]
  service_account_name      = split(":", var.sa_subject)[1]

  ##############################################################################
  # The custody Deny — BUILT HERE, appended to whatever policy_json carries
  #
  # MONEY PATH. tenants/{env}/{org}/{app}/external/ holds a client's Dataprev
  # credential, and the gateway pays real cost for it to be immutable: a variable
  # validation refuses PutSecretValue there, so rotation writes a NEW version path
  # and the audit trail cannot be rewritten. That is a property of ONE role unless
  # the role next door is refused too — and this role's Allow over tenants/
  # necessarily covers the custody ARNs. A Deny on writes alone would leave the
  # control plane able to READ the credential out of the vault, which is the
  # exfiltration half of the same problem, so both directions are denied.
  #
  # THE ROOT BUILDS IT INSTEAD OF DEMANDING IT. An earlier cut required the tfvars
  # to carry this statement and refused the plan when it did not, which meant
  # recognising the statement: pattern-matching an ARN, a verb list and the
  # absence of Condition/NotAction/NotResource — a hunt for lookalikes that each
  # round of review kept finding one more of (wrong account, missing trailing
  # wildcard, segment appended after it, verbs dropped, Deny neutralised by a
  # Condition). Building the statement here makes the invariant true BY
  # CONSTRUCTION: there is no document this root can attach without it, no regex,
  # and no error message that has to describe the ARN correctly to be useful.
  #
  # A Deny in policy_json on top of this one is additive — IAM takes the union of
  # denies — so a tfvars that also carries one is accepted rather than detected.
  ##############################################################################
  custody_deny_statement = {
    Sid    = "DenyDataprevCustodyPaths"
    Effect = "Deny"

    # deny_actions of products/tenant-manager/secrets, verbatim: five writes and
    # three reads. Nominal rather than secretsmanager:*, so widening the Allow
    # later cannot quietly outgrow the Deny.
    Action = [
      "secretsmanager:CreateSecret",
      "secretsmanager:PutSecretValue",
      "secretsmanager:UpdateSecret",
      "secretsmanager:RestoreSecret",
      "secretsmanager:DeleteSecret",
      "secretsmanager:GetSecretValue",
      "secretsmanager:BatchGetSecretValue",
      "secretsmanager:DescribeSecret",
    ]

    # The trailing * is one IAM wildcard and it crosses "/", so external/* already
    # covers the measured custody path at any depth
    # (external/{target}/credentials/versions/{uuid}, plus the six random
    # characters Secrets Manager suffixes onto every secret ARN).
    #
    # Partition, region and account come from the apply itself: a hardcoded ARN
    # copied between estates denies secrets that do not exist here.
    Resource = "arn:${data.aws_partition.current.partition}:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:tenants/*/*/*/external/*"
  }

  # Statement is normalised through flatten() because IAM accepts a single
  # statement object as well as a list; merge() keeps Version and any other
  # top-level key of the transcribed document intact.
  policy_with_custody_deny = jsonencode(merge(
    jsondecode(var.policy_json),
    {
      Statement = concat(
        flatten([try(jsondecode(var.policy_json).Statement, [])]),
        [local.custody_deny_statement],
      )
    }
  ))
}

################################################################################
# The peer cluster's issuer, copied into this account
#
# Same shape the SaaS estate uses (environments/production/platform/iam/
# tenant_manager_cross_account/oidc_provider.tf). client_id_list is the audience
# EKS puts in the token; the thumbprint is the AWS-managed root CA, constant.
#
# This resource is a fact about ANOTHER account's cluster. Recreating that
# cluster changes the issuer URL, which replaces this provider and every trust
# policy that names it — so the URL is an input written after the cluster exists,
# never a value derived here.
################################################################################

resource "aws_iam_openid_connect_provider" "peer_cluster" {
  url             = var.oidc_issuer_url
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [var.oidc_thumbprint]

  tags = merge(module.naming.tags, { Name = "${module.naming.name}-oidc" })
}

################################################################################
# Trust policy
#
# Copied deliberately from _modules/irsa-secretsmanager/main.tf so there is one
# trust shape in this repository rather than two.
#
# :sub IS THE BOUNDARY, :aud IS THE BELT AND BRACES. :sub pins the exact
# ServiceAccount, and it alone is what keeps every other pod in the control-plane
# cluster out: every projected token in that cluster is signed by the same issuer,
# so without :sub the role would be assumable by all of them. :aud pins
# sts.amazonaws.com, which the OIDC provider's client_id_list already requires —
# a token minted for another audience is refused before any condition is read. It
# is written out because AWS documents pinning both for web-identity trust, and
# because a future second audience in client_id_list would otherwise widen this
# role silently.
################################################################################

data "aws_iam_policy_document" "assume_role" {
  statement {
    sid     = "AllowPeerClusterServiceAccountToAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.peer_cluster.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = ["system:serviceaccount:${local.service_account_namespace}:${local.service_account_name}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name                  = var.role_name
  description           = "Cross-account role for ${local.service_account_namespace}/${local.service_account_name} in the control-plane cluster to provision in this account"
  assume_role_policy    = data.aws_iam_policy_document.assume_role.json
  force_detach_policies = true

  # The AWS default (1 hour), written out because it is the ceiling on a
  # credential that crosses an account boundary. Raising it does not make the
  # workload more reliable: the EKS pod identity webhook refreshes the projected
  # token well inside the hour, so a longer session only lengthens the window in
  # which a leaked token is still usable.
  max_session_duration = 3600

  tags = merge(module.naming.tags, { Name = var.role_name })
}

################################################################################
# Grants — one inline policy, transcribed
#
# INLINE and not managed: an inline policy cannot be attached to a second
# principal. This document is the widest reach on the estate (it writes tenant
# credentials), and a managed policy of the same content is one `attach` away
# from being held by something else. Deleting the role deletes it too, with no
# orphan left behind to attach later.
#
# The ALLOW content lives in the tfvars because it is a transcription of what the
# in-account role emits today, and a transcription belongs where it can be diffed
# against its source and argued with in review. The custody Deny does NOT: this
# root appends it to every document it attaches, so it cannot be dropped, narrowed
# or mistyped in a tfvars.
################################################################################

resource "aws_iam_role_policy" "this" {
  name = "${var.role_name}-policy"
  role = aws_iam_role.this.id

  # Not var.policy_json: the transcribed Allow plus the custody Deny this root
  # builds. See locals above — the Deny is not something the tfvars can forget.
  policy = local.policy_with_custody_deny
}

################################################################################
# Policies borrowed from another root
#
# products/tenant-manager/s3 creates no role of its own; it emits managed
# policies for whichever role the ServiceAccount actually annotates. Same
# mechanism as _modules/irsa-secretsmanager's `additional` attachment, for the
# same reason: one ServiceAccount, one role-arn, several concerns.
################################################################################

resource "aws_iam_role_policy_attachment" "additional" {
  for_each = toset(var.additional_policy_names)

  role       = aws_iam_role.this.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:policy/${each.value}"
}
