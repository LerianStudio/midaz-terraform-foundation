################################################################################
# products/tenant-manager/secrets — the provisioning identity of the control plane
#
# THIS IS THE WIDEST IDENTITY ON THE ESTATE, and it is wide because tenant-manager
# is the thing that provisions tenants: it creates databases, vhosts, Kafka
# principals, Casdoor applications and M2M credentials, and it stores every one of
# the resulting secrets in the vault. MongoDB holds only the REFERENCE; the secret
# itself never leaves Secrets Manager.
#
# WHAT IT DOES TO THE VAULT — five actions, not two, and all of them measured:
#
#   GetSecretValue    reads back admin credentials it wrote earlier
#   CreateSecret      first write of a tenant credential
#   PutSecretValue    subsequent writes — it UPSERTS, unlike the gateway
#   RestoreSecret     un-deletes a secret scheduled for deletion, which is a real
#                     path: it soft-deletes with a 7 day recovery window and then
#                     has to resurrect on re-provision
#   DeleteSecret      both soft (7 day window) and ForceDeleteWithoutRecovery
#   DescribeSecret    existence check on the provisioning path
#   ListSecrets       readiness probe (account-wide; not scopeable)
#
# TagResource is NOT granted: it never calls it.
#
# THE PRODUCTION FORK IN THE ADMIN PATH IS REAL AND SILENT. In production the admin
# credential lives at clusters/production/{dbType}/{service}/shared/admin; in every
# other environment it is clusters/{env}/{dbType}/shared/admin — one segment
# different (internal/domain/secrets/paths.go:64-70). Getting it wrong gives a 404
# on credential lookup, not a configuration error. Both prefixes are covered below
# by scoping to clusters/ rather than to a full path.
#
# THE MISSING ENV SEGMENT IS ALSO REAL. Several provisioning handlers pass the
# environment as the empty string, which yields clusters/{dbType}/{service}/... with
# NO env segment (paths.go:44-47), and one code path writes
# tenants/{tenantID}/{stackName}/admin with the UUID dashes intact, unlike every
# other builder. A prefix of "clusters/production/" matches neither. The tfvars
# therefore scopes to the two ROOTS — "tenants/" and "clusters/" — and says so out
# loud, rather than pretending a tighter scope that would break in production.
#
# EVERYTHING BEYOND THE VAULT RIDES THE SAME ROLE. tenant-manager instantiates
# CloudFormation, RDS, DocDB, EC2 and S3 clients with the same identity
# (internal/bootstrap/wire_infra_aws.go). Those grants go in
# var.extra_policy_statements, in the tfvars, where they can be read and argued
# with — not buried in a module default.
#
# TWO THINGS IT DOES *NOT* NEED, both of which look like they should be here:
#
#   kafka:* — MSK users and ACLs are created over the KAFKA WIRE PROTOCOL with
#   franz-go/kadm, not through the AWS API (internal/adapters/msk/
#   provisioner_acl.go:94-99). What it needs is network egress to the broker port,
#   which is a security group, not IAM.
#
#   s3:GetObject on the CloudFormation template bucket — the templates are fetched
#   over plain HTTPS from a hardcoded PUBLIC url in sa-east-1
#   (internal/pkg/cftemplate/url.go:23), bypassing the SDK and IAM entirely.
#   CFN_TEMPLATE_S3_BUCKET buys a readiness HeadBucket and nothing else.
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
  write_actions        = var.write_actions
  allow_list_secrets   = var.allow_list_secrets
  kms_key_arns         = var.kms_key_arns

  extra_policy_statements = var.extra_policy_statements
}
