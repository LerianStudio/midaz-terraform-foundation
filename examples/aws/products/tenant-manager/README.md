# `tenant-manager`

The provisioning control plane: it onboards tenants, creates their databases,
vhosts, Kafka principals, Casdoor applications and M2M credentials, and records
only *references* to the resulting secrets.

| Root | What it provisions |
|---|---|
| `documentdb` | Its own datastore |
| `valkey` | Cache and idempotency store |
| `s3` | Migration SQL and Casdoor templates |
| `secrets` | IRSA — the widest identity on the estate |

**It has no Postgres of its own.** There is no `pgxpool` in the repository and no
`POSTGRES_*` variable in its configuration; every `sql.Open` is against *another*
service's tenant database, with admin credentials fetched from the vault at call
time.

## Two departures from the repository's default posture, both deliberate

`documentdb_tls = "enabled"` and `transit_encryption_mode = "required"` +
`auth_token_enabled = true`. Every other tfvars in this repository ships the loose
setting, labelled a KNOWN GAP, because most charts have nowhere to put a password or
a CA bundle. tenant-manager does: it reads `MONGODB_TLS`, `REDIS_TLS`,
`REDIS_PASSWORD` and `REDIS_CA_CERT`, and the CA is **base64 PEM, not a file path**,
so External Secrets can deliver it with nothing mounted. The reasoning is in each
tfvars header.

## Three traps

**`retryWrites=false` is not added for you.** tenant-manager appends it only to the
tenant URIs it provisions, never to its own `MONGODB_URI`. DocumentDB does not
implement retryable writes and the driver enables them by default, so it must be in
the URI string itself.

**Do not set `REDIS_USERNAME`.** ElastiCache auth tokens are the legacy
password-only AUTH with no username. A non-empty value switches the service onto a
direct ACL client that sends `AUTH <user> <token>`, which the server rejects.

**`CFN_TEMPLATE_S3_BUCKET` buys nothing but a readiness probe.** The CloudFormation
templates come over plain HTTPS from a hardcoded public URL in `sa-east-1`,
bypassing the S3 SDK and IAM entirely.

## Why `secrets` is scoped so widely

To the two vault roots, `tenants/` and `clusters/`, rather than to an environment.
Three measured path shapes make a tighter scope wrong: the production fork
(`clusters/production/{dbType}/{service}/shared/admin` vs
`clusters/{env}/{dbType}/shared/admin`), several handlers that pass the environment
as the empty string and drop the segment entirely, and one builder that keeps UUID
dashes. Each mismatch is a 404 mid-provisioning, not a plan error. Narrow it after
those are fixed upstream.
