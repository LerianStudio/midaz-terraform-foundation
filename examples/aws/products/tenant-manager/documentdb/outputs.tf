################################################################################
# Outputs
#
################################################################################
# helm_values IS NOT DERIVED FROM A CHART, because tenant-manager has no readable
# one: infrastructure/K8S/helm/charts/tenant-manager/ holds two vendored tarballs
# (mongodb-16.4.0.tgz, valkey-0.7.4.tgz) and nothing else — no Chart.yaml, no
# values.yaml, no templates/. Both were extracted and read: the only environment
# variables inside them are the Bitnami MONGODB_* family that configures the
# MongoDB POD, plus VALKEY_LOGLEVEL. Those name what the datastore containers
# read, not what tenant-manager reads, and they are irrelevant the moment the
# datastore is DocumentDB instead of a pod.
#
# Guessing MONGO_HOST / MONGO_URI from a sibling chart would look verified, review
# clean, and silently produce a release that never connects — the three charts read
# for this batch use three DIFFERENT spellings. The keys emitted below come from
# the service's own configuration struct instead; see the Helm handoff header.
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
  description = "EKS cluster whose node security group was looked up. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to tenant-manager."
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
  description = "Raw AWS writer endpoint of the cluster. In shared mode this is the writer endpoint of shared-{env}-docdb, resolved by identifier. This is the value tenant-manager's Mongo host variable needs — whatever that variable turns out to be called."
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
  description = "ARN of the Secrets Manager secret holding the master password: tenant-manager-{env}-docdb/password in dedicated mode, shared-{env}-docdb/password in shared mode."
  value       = module.documentdb.secret_arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret holding the master password. This is the value an External Secrets Operator ExternalSecret references — the chart-side key it should be projected into is unknown until tenant-manager's chart is available."
  value       = module.documentdb.secret_name
}

output "identifier" {
  description = "DocumentDB cluster identifier: tenant-manager-{environment}-docdb in dedicated mode, the resolved shared-{env}-docdb in shared mode."
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
# Helm handoff
#
# tenant-manager's chart is NOT in this monorepo and NOT in its own repository —
# it lives in the internal gitops repo. So the key names below do not come from a
# chart at all; they come from the service's configuration struct
# (internal/bootstrap/config.go:61-74), which is the authority a chart would have
# to match anyway.
#
# THE PREFIX IS MONGODB_, NOT MONGO_. Sibling charts in this repository use three
# different spellings (plugin-fees MONGO_HOST, product-console MONGO_HOST +
# MONGODB_DB_NAME, midaz its own). None of them is this service.
#
# retryWrites=false IS NOT ADDED FOR YOU, AND DOCUMENTDB REJECTS THE DEFAULT.
# tenant-manager appends retryWrites=false only to the URIs it builds for TENANTS
# it provisions (internal/pkg/awsconn/conn.go:38-44). Its OWN MONGODB_URI is passed
# through with only tls parameters appended (internal/bootstrap/config_pure.go:171-181).
# DocumentDB does not implement retryable writes, and the driver enables them by
# default, so a URI without it fails on the first write with an error that names
# neither DocumentDB nor the option. IT MUST BE IN THE URI STRING ITSELF, which is
# why the URI is composed in the ExternalSecret template rather than emitted here.
#
# NO CA BUNDLE, AND NONE IS WANTED. MONGODB_TLS=true makes the service append
# tls=true&tlsInsecure=true (config_pure.go:181) — verification is skipped
# deliberately because DocumentDB presents Amazon's own CA and there is no env var
# to point at a bundle. This is what makes TLS reachable here WITHOUT the chart
# change the other Mongo consumers need, so documentdb_tls = "enabled" is a real
# option for this tier rather than an aspiration. See the tfvars.
#
# The URI carries the password, and no output in this repository carries a
# password, so the URI itself is assembled by External Secrets from the secret this
# stack wrote.
################################################################################

output "helm_values" {
  description = "tenant-manager env vars this datastore fills in. MONGODB_URI is deliberately absent: it contains the password AND must carry retryWrites=false, which DocumentDB requires and the service does not add to its own URI. Compose it in an ExternalSecret template — see mongodb_uri_template_hint."
  value = {
    MONGODB_DATABASE = "tenant_manager"
    MONGODB_TLS      = var.documentdb_tls == "enabled" ? "true" : "false"
  }
}

output "mongodb_uri_template_hint" {
  description = "Shape of the ExternalSecret template that produces MONGODB_URI. retryWrites=false is MANDATORY on DocumentDB — the driver enables retryable writes by default, DocumentDB does not implement them, and the resulting first-write failure names neither. tls parameters are appended by the service itself when MONGODB_TLS=true, so they are not in this template."
  value       = "mongodb://{{ .username }}:{{ .password }}@ENDPOINT:PORT/?retryWrites=false"
}
