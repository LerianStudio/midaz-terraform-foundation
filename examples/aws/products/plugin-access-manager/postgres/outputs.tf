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
  description = "EKS cluster whose node security group was looked up. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to plugin-access-manager."
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
  description = "Raw AWS hostname of the instance — the DB_HOST the Casdoor connection string is built from. In shared mode this is the hostname of shared-{env}-postgres, resolved by name."
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
  description = "ARN of the Secrets Manager secret holding the master credentials: plugin-access-manager-{env}-postgres/password in dedicated mode, shared-{env}-postgres/password in shared mode."
  value       = module.postgres.secret_arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret holding the master credentials. See the DB_PASSWORD note in helm_values: with the bundled subchart disabled, the chart resolves the password through auth.secrets.DB_PASSWORD or through auth-database.auth.existingSecret, and the External Secrets Operator ExternalSecret targets whichever of the two the release is configured for."
  value       = module.postgres.secret_name
}

output "identifier" {
  description = "RDS DB instance identifier: plugin-access-manager-{environment}-postgres in dedicated mode, the resolved shared-{env}-postgres in shared mode."
  value       = module.postgres.identifier
}

################################################################################
# PostgreSQL specifics
################################################################################

output "database_name" {
  description = "Name of the initial database RDS created. MUST be \"casdoor\": templates/auth-backend/configmap.yaml:10 hard-codes dbName: casdoor as a literal Casdoor Beego setting, not templated from any values key."
  value       = module.postgres.database_name
}

output "username" {
  description = "Master username of the instance. Feeds DB_USER. The chart's own default is \"auth\" (values.yaml:284), the role the bundled Bitnami subchart creates and which does not exist on a fresh RDS instance."
  value       = module.postgres.username
}

output "replica_endpoint" {
  description = "Raw AWS hostname of the read replica. Null when no replica was created, and null in shared mode. Casdoor builds one connection string and has no reader variable, so nothing consumes this."
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
# Verified against chart plugin-access-manager 8.6.0 (appVersion 3.1.0),
# templates/auth/configmap.yaml lines 75-79 and values.yaml lines 284-288.
#
# ONE CONFIGMAP FEEDS TWO COMPONENTS. Everything below goes into
# `auth.configmap` and nowhere else. The auth-backend (Casdoor) Deployment does
# NOT have its own database ConfigMap: it pulls DB_HOST, DB_PORT, DB_USER,
# DB_NAME and DB_SSLMODE with configMapKeyRef against the auth component's
# ConfigMap (templates/auth-backend/deployment.yaml:74-98) and assembles
# Casdoor's dataSourceName from them in a shell command at container start
# (:68). The two Jobs — templates/auth-backend/migrations.yaml and
# templates/auth/init_user.yaml — read the same ConfigMap. The IDENTITY
# component has no database variables at all.
#
# So: set these five keys once, on auth.configmap, and all three consumers
# follow. Setting them on identity.configmap does nothing.
#
# THE SUBCHART IS ALIASED. The bundled PostgreSQL is declared as
# `name: postgresql, alias: auth-database` (Chart.yaml:32-36), so the values key
# is `auth-database`, not `postgresql`. Turning it off is
# `auth-database.enabled = false` (values.yaml:405).
#
# Values are strings because they end up in a ConfigMap.
#
# NOT emitted here, on purpose:
#   DB_PASSWORD  — read from secret_name by External Secrets, never an output.
#     Its resolution is unusual in this chart: templates/_helpers.tpl:168-196
#     ("plugin-auth.dbPasswordEnv") prefers auth-database.auth.existingSecret,
#     then the bundled subchart's own generated Secret, and only falls back to
#     auth.secrets.DB_PASSWORD. Note also that the two Jobs name the variable
#     DB_PASS, not DB_PASSWORD.
#   DB_SSLMODE   — a client policy decision, not an infrastructure fact, and the
#     same call the midaz root makes about its DB_*_SSLMODE. Chart default
#     "disable" (values.yaml:288). Beware the spelling drift when setting it:
#     the ConfigMap key is DB_SSLMODE, the auth-backend migrations Job reads
#     DB_SSLMODE, and templates/auth/init_user.yaml:76 exposes the same value to
#     its container as DB_SSL_MODE, with the underscore.
#   USER_EXECUTE_COMMAND — chart default "postgres"
#     (templates/auth/configmap.yaml:80). It happens to match this stack's
#     default master username, but it is an application setting, not a fact
#     about the instance, so it is not emitted from here.
################################################################################

output "helm_values" {
  description = "plugin-access-manager chart env vars this datastore fills in, ready to merge into auth.configmap ONLY — auth-backend and both Jobs read the same ConfigMap by reference, and identity has no database variables. Pair it with auth-database.enabled = false (values.yaml:405) so the bundled Bitnami subchart is not deployed alongside RDS."
  value = {
    DB_HOST = module.postgres.endpoint
    DB_PORT = tostring(module.postgres.port)
    DB_NAME = module.postgres.database_name
    DB_USER = module.postgres.username
  }
}
