################################################################################
# Outputs
#
################################################################################
# helm_values IS EMPTY, ON PURPOSE. IT IS NOT AN OVERSIGHT.
#
# Every other product root in this repository ends in a helm_values map holding
# the exact environment variable names its chart reads. This one cannot, because
# flowker has no readable chart:
# infrastructure/K8S/helm/charts/flowker/ contains two vendored tarballs
# (mongodb-16.4.0.tgz, valkey-0.7.4.tgz) and nothing else — no Chart.yaml, no
# values.yaml, no templates/.
#
# Both tarballs were extracted and read. They are unmodified upstream charts:
# the only literal environment variables inside them are the Bitnami MONGODB_*
# family that configures the MongoDB POD (MONGODB_ROOT_USER, MONGODB_PORT_NUMBER,
# MONGODB_REPLICA_SET_MODE and so on) and a single VALKEY_LOGLEVEL. Those name
# what the datastore containers read, not what flowker reads, and they are
# irrelevant the moment the datastore is DocumentDB instead of a pod. Searching
# the extracted trees for MONGO_ (single word), REDIS_, POSTGRES, RABBIT, AMQP,
# STREAMING_, KAFKA and BROKER returns zero matches.
#
# Guessing MONGO_HOST / MONGO_URI here because three sibling charts use them
# would be the single most damaging thing this file could do: it looks verified,
# it reviews clean, and it silently produces a release that never connects. The
# three charts read for this batch use three DIFFERENT spellings — plugin-fees
# MONGO_HOST, product-console MONGODB_DB_NAME/MONGO_HOST, midaz
# MONGO_ONBOARDING_HOST — which is exactly the evidence that there is no
# convention to fall back on.
#
# WHAT TO DO INSTEAD. The endpoint, port, secret name and master username are
# all published as ordinary outputs below and are correct. Hand them to the team
# that owns flowker, and once the chart lands in this monorepo, add the
# helm_values map here from ITS values.yaml, not from a sibling's.
#
################################################################################
#
# The seven uniform contract names (mode, endpoint, port, security_group_id,
# secret_arn, secret_name, identifier) are passed straight through from the
# module, unchanged — those are infrastructure facts and are unaffected by the
# missing chart.
#
# There is no dns_name output and no private zone: every AWS datastore presents
# a certificate for its own service domain, so a CNAME in front of it breaks TLS
# hostname verification. `endpoint` is the raw AWS host in both modes.
################################################################################

################################################################################
# Cross-stack context (assert the derived strings without opening the tfvars)
################################################################################

output "vpc_name" {
  description = "tag:Name of the VPC the cluster was placed in, as derived or overridden. Should equal the vpc_name output of infra-base/vpc."
  value       = module.network.vpc_name
}

output "eks_cluster_name" {
  description = "EKS cluster whose node security group was looked up. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to flowker."
  value       = module.network.eks_cluster_name
}

output "ingress_security_group_ids" {
  description = "Security groups authorised on the cluster. Empty before infra-base/eks exists unless allowed_security_group_ids was passed explicitly."
  value       = module.network.ingress_security_group_ids
}

output "ingress_cidr_blocks" {
  description = "CIDR blocks authorised on the cluster. Holds the Type=private subnet CIDRs while allow_private_subnet_cidr_ingress is true."
  value       = module.network.ingress_cidr_blocks
}

################################################################################
# Uniform datastore contract
################################################################################

output "mode" {
  description = "Provisioning mode this stack ran in: dedicated or shared."
  value       = module.documentdb.mode
}

output "endpoint" {
  description = "Raw AWS writer endpoint of the cluster. In shared mode this is the writer endpoint of shared-{env}-docdb, resolved by identifier. This is the value flowker's Mongo host variable needs — whatever that variable turns out to be called."
  value       = module.documentdb.endpoint
}

output "port" {
  description = "Port the cluster listens on."
  value       = module.documentdb.port
}

output "security_group_id" {
  description = "Security group protecting the cluster. Null in shared mode — ingress on the shared cluster is owned by products/shared-resources/documentdb."
  value       = module.documentdb.security_group_id
}

output "secret_arn" {
  description = "ARN of the Secrets Manager secret holding the master password: flowker-{env}-docdb/password in dedicated mode, shared-{env}-docdb/password in shared mode."
  value       = module.documentdb.secret_arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret holding the master password. This is the value an External Secrets Operator ExternalSecret references — the chart-side key it should be projected into is unknown until flowker's chart is available."
  value       = module.documentdb.secret_name
}

output "identifier" {
  description = "DocumentDB cluster identifier: flowker-{environment}-docdb in dedicated mode, the resolved shared-{env}-docdb in shared mode."
  value       = module.documentdb.identifier
}

################################################################################
# DocumentDB specifics
################################################################################

output "reader_endpoint" {
  description = "Raw AWS reader endpoint of the cluster, for read-only consumers. Resolved from the shared cluster in shared mode."
  value       = module.documentdb.reader_endpoint
}

output "arn" {
  description = "ARN of the DocumentDB cluster. Resolved from the shared cluster in shared mode."
  value       = module.documentdb.arn
}

output "kms_key_arn" {
  description = "ARN of the CMK encrypting the cluster storage. Null in shared mode."
  value       = module.documentdb.kms_key_arn
}

output "master_username" {
  description = "Master username configured on the cluster. Read from the stack variable rather than from the module output, which is marked sensitive."
  value       = var.master_username
}

output "tls_enabled" {
  description = "Whether the cluster `tls` parameter is enabled."
  value       = var.documentdb_tls == "enabled"
}

################################################################################
# Helm handoff — intentionally EMPTY. Read the header of this file.
################################################################################

output "helm_values" {
  description = "EMPTY BY DESIGN, and the only empty helm_values in this repository. flowker has no readable Helm chart (infrastructure/K8S/helm/charts/flowker/ holds two vendored tarballs and no Chart.yaml), so no environment variable name can be verified. Consume `endpoint`, `port`, `master_username` and `secret_name` directly and map them by hand until the chart is available. Emitting plausible names from a sibling chart would produce a release that fails to connect for a reason nobody would look for here."
  value       = {}
}
