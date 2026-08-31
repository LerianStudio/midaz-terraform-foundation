################################################################################
# Outputs
#
# The seven uniform contract names (mode, endpoint, port, security_group_id,
# secret_arn, secret_name, identifier) are passed straight through from the
# module, unchanged, so every products/*/* root answers `terraform output` the
# same way regardless of which datastore it wraps.
#
# There is no dns_name output and no private zone: every AWS datastore presents
# a certificate for its own service domain, so a CNAME in front of it breaks TLS
# hostname verification. `endpoint` is the raw AWS host in both modes.
#
# The module is NOT under count here — this root stack wraps exactly one
# datastore — so a plain module.postgres.x reference is safe.
################################################################################

################################################################################
# Cross-stack context (assert the derived strings without opening the tfvars)
################################################################################

output "vpc_name" {
  description = "tag:Name of the VPC the instance was placed in, as derived or overridden. Should equal the vpc_name output of infra-base/vpc."
  value       = module.network.vpc_name
}

output "eks_cluster_name" {
  description = "EKS cluster whose node security group was looked up. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to streaming-hub."
  value       = module.network.eks_cluster_name
}

output "ingress_security_group_ids" {
  description = "Security groups authorised on the instance. Empty before infra-base/eks exists unless allowed_security_group_ids was passed explicitly."
  value       = module.network.ingress_security_group_ids
}

output "ingress_cidr_blocks" {
  description = "CIDR blocks authorised on the instance. Holds the Type=private subnet CIDRs while allow_private_subnet_cidr_ingress is true."
  value       = module.network.ingress_cidr_blocks
}

################################################################################
# Uniform datastore contract
################################################################################

output "mode" {
  description = "Provisioning mode this stack ran in: dedicated or shared."
  value       = module.postgres.mode
}

output "endpoint" {
  description = "Raw AWS hostname of the instance — the DB_HOST the streaming-hub connection string is built from. In shared mode this is the hostname of shared-{env}-postgres, resolved by name."
  value       = module.postgres.endpoint
}

output "port" {
  description = "PostgreSQL port."
  value       = module.postgres.port
}

output "security_group_id" {
  description = "Security group protecting the instance. Null in shared mode — ingress on the shared instance is owned by products/shared-resources/postgres."
  value       = module.postgres.security_group_id
}

output "secret_arn" {
  description = "ARN of the Secrets Manager secret holding the master credentials: streaming-hub-{env}-postgres/password in dedicated mode, shared-{env}-postgres/password in shared mode."
  value       = module.postgres.secret_arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret holding the master credentials: streaming-hub-{env}-postgres/password. There is no DB_PASSWORD on this service and no bundled subchart to disable — it reads ONE DSN string, and the ExternalSecret templates that DSN from this secret's JSON payload {username,password,engine,host,port,dbname}. See dsn_template_hint. THIS NAME MUST APPEAR IN THE ESO ROLE'S secret_path_prefixes, and note that it starts with neither tenants/ nor clusters/."
  value       = module.postgres.secret_name
}

output "identifier" {
  description = "RDS DB instance identifier: streaming-hub-{environment}-postgres in dedicated mode, the resolved shared-{env}-postgres in shared mode."
  value       = module.postgres.identifier
}

################################################################################
# PostgreSQL specifics
################################################################################

output "database_name" {
  description = "Name of the initial database RDS created. MUST be \"streaminghub\": templates/auth-backend/configmap.yaml:10 hard-codes dbName: streaminghub as a literal streaming-hub Beego setting, not templated from any values key."
  value       = module.postgres.database_name
}

output "username" {
  description = "Master username of the instance. Feeds DB_USER. The chart's own default is \"auth\" (values.yaml:284), the role the bundled Bitnami subchart creates and which does not exist on a fresh RDS instance."
  value       = module.postgres.username
}

output "replica_endpoint" {
  description = "Raw AWS hostname of the read replica. Null when no replica was created, and null in shared mode. streaming-hub builds one connection string and has no reader variable, so nothing consumes this."
  value       = module.postgres.replica_endpoint
}

output "replica_identifier" {
  description = "RDS DB instance identifier of the read replica. Null when no replica was created."
  value       = module.postgres.replica_identifier
}

output "subnet_group_name" {
  description = "Name of the DB subnet group. Null in shared mode."
  value       = module.postgres.subnet_group_name
}

################################################################################
# Helm handoff
#
# streaming-hub has no chart in its repository and none in the deployer's chart
# directory — the one service of this wire where the absence was actually measured.
# The key names below come from the service's own configuration
# loader (internal/bootstrap/config_load.go:21-24), which is the only authority
# there is and the one a future chart will have to match.
#
# THE SERVICE TAKES A SINGLE DSN, NOT HOST/PORT/USER/PASSWORD, AND THAT IS WHY THE
# CONNECTION IS NOT EMITTED HERE. STREAMING_HUB_POSTGRES_DSN is one string that
# CONTAINS THE PASSWORD, and no output in this repository carries a password — the
# only two sensitive outputs anywhere are usernames.
#
# The DSN is assembled by External Secrets from the RDS secret, which _modules/
# postgres-rds deliberately writes as JSON rather than as a bare string precisely so
# it can be templated:
#
#   {"username":...,"password":...,"engine":...,"host":...,"port":...,"dbname":...}
#
# An ExternalSecret with a template stanza builds
#   postgres://{{ .username }}:{{ .password }}@{{ .host }}:{{ .port }}/{{ .dbname }}?sslmode=require
# and projects it as STREAMING_HUB_POSTGRES_DSN. Reproducing host and port here as
# separate keys would invite somebody to wire them into a chart that has nowhere to
# put them.
#
# sslmode=require IS NOT OPTIONAL and belongs in that template. The parameter group
# sets rds.force_ssl = 1, so the SERVER refuses a plaintext connection; without the
# client asking for TLS the pod simply fails to connect. Belt and braces, in that
# order.
#
# POOL SIZING IS A REAL CONSTRAINT, not tuning. The hub runs several roles with
# different pool sizes and the invariant is
#   sum(replicas x max_open_conns) <= max_connections
# of this instance. Exceed it and the symptom is intermittent connection refusals
# under load, not a startup error.
################################################################################

output "helm_values" {
  description = "EMPTY ON PURPOSE. streaming-hub takes a single STREAMING_HUB_POSTGRES_DSN containing the password, and no output here carries a password. Build the DSN in an ExternalSecret template over the JSON RDS secret (secret_name output), with sslmode=require — the parameter group sets rds.force_ssl = 1, so a client that does not ask for TLS is refused by the server."
  value       = {}
}

output "dsn_template_hint" {
  description = "The shape of the ExternalSecret template that produces STREAMING_HUB_POSTGRES_DSN from the JSON secret this stack wrote. Not a value to paste into a chart — a reminder of which keys the JSON carries and that sslmode is mandatory."
  value       = "postgres://{{ .username }}:{{ .password }}@{{ .host }}:{{ .port }}/{{ .dbname }}?sslmode=require"
}
