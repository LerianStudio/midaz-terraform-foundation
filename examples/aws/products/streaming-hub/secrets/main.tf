################################################################################
# products/streaming-hub/secrets — the roster identity of the event hub
#
# WHY THIS ROLE IS THE DIFFERENCE BETWEEN A RUNNING HUB AND A CRASHLOOP.
#
# In multi-tenant mode the hub does not read a tenant list from configuration. It
# BUILDS one by listing the vault: every secret named tenants/{env}/{tenantId}/
# {module}/kafka is one tenant it will serve (internal/tenantinventory/discover.go,
# via lib-commons ListModuleKafkaSecrets). An empty listing is not an empty roster,
# it is a refusal to boot. So a missing ListSecrets grant does not surface as a
# permission error — it surfaces as a pod that will not start, with a message about
# tenants rather than about IAM.
#
# It reads NAMES ONLY on that path. GetSecretValue on the Kafka leaves is no longer
# required; the inventory never decodes a payload
# (cmd/app/main.go:229-230: "ListSecrets is the only call it makes"). The one place
# it does fetch a value is its own M2M manifest credential, under
# tenants/{env}/{tenantOrgID}/streaming-hub/m2m/{targetService}/credentials.
#
# ListSecrets IS ACCOUNT-WIDE AND CANNOT BE NARROWED. AWS does not evaluate it
# against a resource. The hub therefore learns every secret NAME in the account and
# no value. That is a real widening and it is why the module makes it its own
# variable rather than folding it into a read grant.
#
# GRANT IT TO EVERY POD, NOT JUST THE INGEST ROLE. The roster is built at BOOT, by
# every role — all, ingest and delivery alike. Scoping the annotation to one
# Deployment produces a delivery pod that crashloops while the ingest pod is
# healthy, which reads like a delivery bug for a long time.
#
# THE KEK IS NOT HERE, AND THAT IS THE TRAP WORTH NAMING. The hub's key-encryption
# key looks like a Secrets Manager dependency — STREAMING_HUB_KEK_SOURCE even
# accepts the literal "secretsmanager". It is not. Both "env" and "secretsmanager"
# resolve through the SAME env-var source and no AWS SDK is involved
# (internal/bootstrap/service.go:1932-1946; internal/secrets/kek_source.go has
# exactly two implementations and neither talks to AWS). The KEK reaches the pod as
# an environment variable projected by External Secrets, so what it needs is a
# secret in the vault plus an ExternalSecret — see products/lerian-platform/eso —
# NOT a grant on this role. An empty KEK makes the hub REFUSE TO SIGN webhooks
# rather than degrade, so getting this wrong is silent until a delivery fails.
#
# SINGLE-TENANT BYOC MAKES ZERO AWS CALLS. With MULTI_TENANT_ENABLED=false the
# allowlist is the one configured tenant id and nothing reaches the vault. This
# root is only needed in multi-tenant mode.
#
# Deploy order: infra-base/eks -> this stack. The OIDC lookup is SINGULAR and fails
# the plan when the cluster does not exist.
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

  deny_secret_path_patterns = var.deny_secret_path_patterns
  deny_actions              = var.deny_actions
  allow_list_secrets        = var.allow_list_secrets
  kms_key_arns              = var.kms_key_arns
}
