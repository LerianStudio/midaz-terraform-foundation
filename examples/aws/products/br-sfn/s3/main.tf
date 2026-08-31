################################################################################
# products/br-sfn/s3 — the object storage of the br-sfn correios rail
#
# ONE ROOT STACK PER SERVICE, same as the datastore siblings: one directory, one
# state file (aws/products/br-sfn/s3/terraform.tfstate).
#
# WHY THIS ROOT EXISTS — the evidence, because the chart does NOT name the keys
# in any template and a grep alone would say "residue".
#
#   1. br-sfn/values.yaml:590-592 states the correios rail's external contract in
#      prose: "Postgres + Valkey/Redis cache + RabbitMQ + S3-compatible object
#      storage, all external." br-sfn/docs/UPGRADE-1.1.md:25,27 repeats it:
#      "Stores attachments in S3-compatible object storage" / "Requires external
#      Postgres, Valkey/Redis cache, RabbitMQ, and S3-compatible storage".
#
#   2. The rail runs THE SAME IMAGE as the standalone product:
#      ghcr.io/lerianstudio/plugin-bc-correios (br-sfn/values.yaml:608 vs
#      plugin-bc-correios/values.yaml:70). That binary genuinely consumes S3 —
#      the standalone chart hardcodes OBJECT_STORAGE_PROVIDER / _ENDPOINT /
#      _BUCKET / _PATH_STYLE (templates/configmap.yaml:47-51) and its init
#      container BLOCKS STARTUP on the endpoint being reachable
#      (templates/deployment.yaml:88-89).
#
#   3. br-sfn/values-template.yaml:75-76 lists OBJECT_STORAGE_ENDPOINT and
#      OBJECT_STORAGE_BUCKET under correios.configmap. Those two lines are
#      COMMENTED OUT and that file is never rendered — it is an operator
#      skeleton the repo validator requires
#      (helm/.github/scripts/validate-helm-charts/main.go:270-272) — so they are
#      documentation of the contract, not the contract itself.
#
#   4. NO br-sfn TEMPLATE NAMES THE KEYS, and it does not have to. correios
#      .configmap is an UNTYPED PASSTHROUGH: br-sfn.componentConfigData
#      mergeOverwrite + toYaml (templates/_helpers.tpl:75-82) into the ConfigMap
#      (:117-129) and out through envFrom (:248-260), with
#      values.schema.json declaring correios.configmap as bare
#      {"type":"object", "additionalProperties":true}. The commit that added the
#      rail says so outright: the predecessor chart used "a FIXED ALLOWLIST of
#      40 keys ... anything off the list vanished silently. br-sfn emits the map
#      verbatim."
#
#   VERDICT: a real dependency the chart declines to type. Not residue. The
#   bucket is created here and the keys are emitted through helm_values into
#   correios.configmap.
#
# THIS ROOT IS SHAPED DIFFERENTLY FROM ITS DATASTORE SIBLINGS, on purpose. Three
# contract points that hold for postgres/valkey/rabbitmq/msk do not hold here,
# and each one is a property of S3 rather than an omission:
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
#
# APPLY THIS ONLY IF THE CORREIOS RAIL IS ENABLED. correios.enabled defaults to
# false (br-sfn/values.yaml:604). With the rail off, the bucket has no writer.
# An empty bucket is close to free, so this is a tidiness rule rather than a
# cost one — but the IRSA role it creates is not nothing.
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
# "lerian-${var.environment}-eks" here would be one more copy of a derivation
# that has exactly one owner. If infra-base ever renames the cluster, the module
# changes and this root follows.
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
#
# ONE SERVICE ACCOUNT FOR THE WHOLE MONOREPO CHART — READ var.service_account.
# br-sfn defines a SINGLE chart-level ServiceAccount shared by every component
# (templates/_helpers.tpl:33-38, "Name of the service account to use (shared by
# every component)"). There is no per-rail ServiceAccount, so the role created
# here is assumable by spb, spi, siloc, scr, slc-edge, desk and cockpit as well
# as correios. That is a chart property this root cannot fix; it is recorded in
# variables.tf and README.md rather than papered over.
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
# Object storage — br-sfn-{environment}-correios-attachments-{account_id}
#
# The account id suffix is the documented naming exception: S3 bucket names are
# globally unique across every AWS account, so br-sfn-{env}-correios-attachments
# alone would collide with any other AWS customer that picked the same words.
# The prefix still comes from the naming module, inside the s3-bucket module.
#
# THE LOGICAL NAME IS "correios-attachments", NOT "bc-correios-attachments".
# The standalone products/plugin-bc-correios/s3 root uses the latter, matching
# that chart's own default. Here the component is called `correios` throughout
# br-sfn — values key, template directory, ConfigMap name — so the bucket
# follows the rail vocabulary of the chart it belongs to. The two buckets are
# distinct resources in any case: the product prefix differs, so nothing
# collides and nothing migrates automatically between them.
#
# correios-attachments holds correspondence attachments exchanged with the
# Brazilian Central Bank, which is why prd carries the longest retention of any
# bucket in this repository.
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
