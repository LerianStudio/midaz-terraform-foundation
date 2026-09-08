################################################################################
# products/br-consignado-gw/secrets — the custody identity of the gateway
#
# The gateway holds each tenant's DATAPREV CREDENTIAL. That is the money path this
# root exists for, and nothing else in the estate has the same shape.
#
# HOW THE CUSTODY STORE WORKS, because the IAM policy only makes sense against it:
#
#   A credential is written under a reference that carries the environment, the
#   tenant, the application and the target service, plus a version:
#
#     tenants/{env}/{tenantOrgID}/br-consignado-gw/external/{target}/credentials/versions/{uuid}
#
#   with {target} one of dataprev-cert or dataprev-oauth — two values on purpose,
#   so rotating the certificate can never overwrite the OAuth secret. On read the
#   gateway RE-PARSES the stored reference and demands exact scope equality, which
#   means a credential written under one environment name is unreadable under
#   another. The environment name is therefore permanent from the first write.
#
#   ON THIS ESTATE THAT NAME IS "production", NOT "prd". var.environment here is
#   the repository's vocabulary and names the IAM objects; the vault segment is the
#   application's ENV_NAME and lives in var.secret_path_prefixes. They differ, and
#   the difference is load-bearing.
#
# WHY CreateSecret + DeleteSecret BUT NEVER PutSecretValue. A version is immutable:
# the gateway stages a new secret at a new version path and never overwrites an old
# one (internal/credentials/adapters/secretsmanager/sm_writer.go — CreateSecret at
# :76, DescribeSecret at :93/:136, DeleteSecret with ForceDeleteWithoutRecovery at
# :109; PutSecretValue appears nowhere). Granting PutSecretValue would make the
# custody audit trail rewritable by the service that is supposed to be audited.
# DeleteSecret is granted because the writer rolls back a failed staged write.
#
# WHY NO ListSecrets. The gateway reads by exact reference and enumerates nothing.
# ListSecrets cannot be resource-scoped, so leaving it off is a real narrowing.
#
# NOTHING IN THIS ROOT PUTS A CREDENTIAL IN THE VAULT. The IaC delivers the role;
# the tenant writes the credential through the gateway's own custody API, with an
# audit trail. No operator ever handles a Dataprev credential, and none of them
# appears in any file in this repository.
#
# Deploy order: infra-base/eks -> this stack. The OIDC lookup below is SINGULAR and
# fails the plan when the cluster does not exist, which is the wanted behaviour: a
# role trusting a provider that is not there applies cleanly and produces pods that
# get AccessDenied on every vault call.
################################################################################

module "network" {
  source = "../../../_modules/product-network"

  enabled     = false
  environment = var.environment

  eks_cluster_name = var.eks_cluster_name
}

locals {
  lookup_oidc_provider = var.oidc_provider_arn == ""

  oidc_provider_arn = var.oidc_provider_arn != "" ? var.oidc_provider_arn : one(data.aws_iam_openid_connect_provider.cluster[*].arn)
}

data "aws_eks_cluster" "cluster" {
  count = local.lookup_oidc_provider ? 1 : 0

  name = module.network.eks_cluster_name
}

data "aws_iam_openid_connect_provider" "cluster" {
  count = local.lookup_oidc_provider ? 1 : 0

  url = data.aws_eks_cluster.cluster[0].identity[0].oidc[0].issuer
}

module "secrets" {
  source = "../../../_modules/irsa-secretsmanager"

  product     = var.product
  environment = var.environment
  component   = var.component
  extra_tags  = var.extra_tags

  oidc_provider_arn = local.oidc_provider_arn
  service_account   = var.service_account

  secret_path_prefixes = var.secret_path_prefixes
  read_actions         = var.read_actions
  write_actions        = var.write_actions
  allow_list_secrets   = var.allow_list_secrets
  kms_key_arns         = var.kms_key_arns

  additional_policy_names = var.additional_policy_names
}
