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
  # no token ever carries, which does not fail the apply: it silently admits every
  # token the provider will sign, because a condition on an absent key is not
  # evaluated. var.oidc_issuer_url is validated to start with the scheme, so this
  # trim always has something to remove.
  oidc_host = trimprefix(var.oidc_issuer_url, "https://")

  service_account_namespace = split(":", var.sa_subject)[0]
  service_account_name      = split(":", var.sa_subject)[1]

  ##############################################################################
  # The custody guard, decided here and enforced on aws_iam_role_policy below
  #
  # A statement counts as the custody Deny when all three hold: Effect is Deny,
  # at least one Resource names the custody path, and the Action list carries
  # BOTH the write verb and the read verb the gateway's immutability depends on.
  #
  # Both directions, deliberately. A Deny on writes alone would leave the control
  # plane able to read a client's Dataprev credential out of the vault, which is
  # the exfiltration half of the same problem.
  #
  # The escaped \* in the pattern is literal: the resource ARN really contains
  # asterisks (tenants/*/*/*/external/*), and an unescaped regex would match
  # "tenants///external/" as happily as the real thing. regexall rather than
  # strcontains keeps this root inside the required_version floor of 1.5.0 that
  # every root here declares.
  #
  # Statement is normalised through flatten() because IAM accepts a single
  # statement object as well as a list, and Action/Resource each accept a bare
  # string as well as a list. A guard that only understood the list form would
  # pass a document written in the other legal shape without reading it.
  ##############################################################################
  custody_resource_pattern = "secret:tenants/\\*/\\*/\\*/external/"

  policy_statements = flatten([try(jsondecode(var.policy_json).Statement, [])])

  custody_deny_matches = [
    for s in local.policy_statements :
    (try(s.Effect, "") == "Deny"
      && anytrue([
        for r in flatten([try(s.Resource, [])]) :
        length(regexall(local.custody_resource_pattern, tostring(r))) > 0
      ])
      && contains(flatten([try(s.Action, [])]), "secretsmanager:PutSecretValue")
    && contains(flatten([try(s.Action, [])]), "secretsmanager:GetSecretValue"))
  ]

  custody_deny_present = anytrue(local.custody_deny_matches)
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
# BOTH CONDITIONS ARE LOAD-BEARING. :sub pins the exact ServiceAccount. :aud pins
# sts.amazonaws.com — and without it ANY pod in the control-plane cluster can
# mint a token for this role, because every projected ServiceAccount token in
# that cluster is signed by the same issuer. The blast radius of dropping one
# line here is "every workload in the control plane can write tenant secrets in
# the application account".
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
# The content lives in the tfvars because it is a transcription of what the
# in-account role emits today, and a transcription belongs where it can be
# diffed against its source and argued with in review.
################################################################################

resource "aws_iam_role_policy" "this" {
  name   = "${var.role_name}-policy"
  role   = aws_iam_role.this.id
  policy = var.policy_json

  lifecycle {
    # MONEY PATH. tenants/{env}/{org}/{app}/external/ holds a client's Dataprev
    # credential, and the gateway pays real cost for it to be immutable: a
    # variable validation refuses PutSecretValue there, so rotation writes a NEW
    # version path and the audit trail cannot be rewritten. That property is a
    # property of ONE role unless the role next door is also refused — and this
    # role's Allow over tenants/ necessarily covers the custody ARNs.
    #
    # A precondition and not a variable validation: the check has to decode the
    # document and walk its statements, and locals are not reachable from a
    # validation block on every version this repository supports. precondition is
    # also the mechanism _modules/irsa-secretsmanager already uses for its own
    # would-grant-nothing guards (main.tf:103,111).
    #
    # It refuses the PLAN, which is the only cheap place: a policy applied without
    # the Deny leaves no error behind, only a control plane that can read and
    # rewrite a client's credential.
    precondition {
      condition     = local.custody_deny_present
      error_message = "policy_json carries no custody Deny. It must contain a statement with \"Effect\": \"Deny\", a Resource matching secret:tenants/*/*/*/external/ and an Action list including BOTH secretsmanager:PutSecretValue and secretsmanager:GetSecretValue (the measured document lists eight verbs there; a bare secretsmanager:* is not accepted, write the verbs). That path holds the client's Dataprev credential: the gateway makes it immutable by refusing PutSecretValue in its own validation, and this control-plane role must be refused both the rewrite and the read or the immutability is worth nothing. Transcribe the deny_actions/deny_secret_path_patterns block from products/tenant-manager/secrets rather than weakening this guard."
    }
  }
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
