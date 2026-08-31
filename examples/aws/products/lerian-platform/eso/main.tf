################################################################################
# products/lerian-platform/eso — the External Secrets Operator identity
#
# WHY A PSEUDO-PRODUCT CALLED lerian-platform. This root is cluster-level: it
# belongs to no product. It nonetheless lives under products/ because that is the
# ONLY place lerian-infra discovers roots — infra.Discover walks products/*/* and
# nothing else, and the infra-base stage is hardcoded to exactly vpc and eks
# (pkg/infra/discover.go:36-78, :128-153). A directory at infra-base/eso would be
# invisible to the CLI and would have to be applied by hand, out of the guarded
# ordering. See ../README.md.
#
# WHAT THIS ROLE IS FOR. Every datastore module here writes its generated
# credential to Secrets Manager, and nothing carries it into a pod. External
# Secrets Operator is the carrier: it reads the vault with THIS role and projects
# each secret into a Kubernetes Secret the workload mounts or reads as an env var.
# Without it the estate has strong credentials nobody can use.
#
# IT IS READ-ONLY, AND IT IS ACCOUNT-WIDE. ESO must be able to project any secret
# any workload asks for, so scoping it to one product's prefix defeats it. What is
# NOT granted is every write action: ESO never creates, updates or deletes a
# secret, and a compromise of the operator therefore cannot destroy a credential,
# only read it. That asymmetry is the whole security value of a separate role.
#
# ListSecrets is granted because ESO's ClusterSecretStore validation and its
# find-by-name/find-by-tag ExternalSecrets enumerate. It cannot be scoped by AWS.
#
# THIS ROOT INSTALLS NOTHING. The operator itself, its ClusterSecretStore and every
# ExternalSecret are Helm, in the phase after this one. Terraform's contribution is
# the role ARN that goes on the operator's ServiceAccount.
#
# TWO SECRETS ON THE CONSIGNADO WIRE DEPEND ON THIS AND ON NOTHING ELSE:
#   - streaming-hub's KEK, which reaches the pod ONLY as an env var. An empty KEK
#     makes the hub refuse to sign webhooks rather than degrade quietly.
#   - the MSK SASL password, which br-consignado-gw reads from a FILE PATH
#     (STREAMING_KAFKA_SASL_PASSWORD_FILE), so it needs a projected volume, not an
#     env var.
#
# Deploy order: infra-base/eks -> this stack.
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

  # Never. ESO projects secrets; it does not author them.
  write_actions = []

  allow_list_secrets = var.allow_list_secrets
  kms_key_arns       = var.kms_key_arns
}
