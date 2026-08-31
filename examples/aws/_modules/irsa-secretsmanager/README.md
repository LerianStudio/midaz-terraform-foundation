# `_modules/irsa-secretsmanager`

The path a secret takes from AWS Secrets Manager into a pod.

Every datastore module in this repository generates a strong credential and writes
it to Secrets Manager. Not one of them grants anybody permission to read it back.
Before this module the repository contained exactly one `secretsmanager:GetSecretValue`
statement — a *resource* policy on the MSK SCRAM secret, for the principal
`kafka.amazonaws.com`. No identity policy, no IRSA role, no variable. Three money
paths depended on that hole being closed by hand:

- **br-consignado-gw** keeps each tenant's Dataprev credential in the vault and
  re-parses the stored reference on read, demanding exact scope equality.
- **tenant-manager** takes its admin credentials for Postgres, Mongo and RabbitMQ
  *only* from the vault — there is no environment-variable fallback.
- **streaming-hub** discovers its tenant roster by listing vault secrets, and an
  empty listing makes it refuse to boot.

## What it creates

One IAM role per invocation, assumable by exactly one Kubernetes service account
through the cluster's OIDC provider, plus one IAM policy per invocation attached to
it. The trust policy is the same `AssumeRoleWithWebIdentity` shape
`_modules/s3-bucket/iam.tf` writes: `:sub` pinned to
`system:serviceaccount:{namespace}:{name}` and `:aud` pinned to `sts.amazonaws.com`.

**One policy per service, never a consolidated one.** Same reason `s3-bucket` keeps
one policy per bucket: the vault holds every tenant's Dataprev credential and every
cluster's admin password, and a consolidated grant would hand all of it to whichever
pod needed any of it. The account limit is 1500 policies, so the split is free.

## The three shapes of grant, and why they are separate variables

`secretsmanager:ListSecrets` **cannot be scoped to a resource.** AWS evaluates it
against the whole account, so a policy that needs it must write `Resource: "*"`.
That is a real widening — the caller learns every secret *name* in the account,
though not a single value — so it is its own opt-in variable (`allow_list_secrets`)
rather than something that rides along with a read grant.

Everything else is scoped by ARN prefix. Secrets Manager appends a random six
character suffix to every secret ARN, so a prefix pattern must end in `*`; the module
appends it, and refuses a pattern that already carries one, so nobody writes `**`.

## The path formats this module exists to scope

Measured, not assumed. All of them are built by `lib-commons/commons/secretsmanager`
and by `tenant-manager/internal/domain/secrets/paths.go`:

```
tenants/{env}/{tenantOrgID}/{app}/external/{targetService}/credentials/versions/{v}
tenants/{env}/{tenantOrgID}/{app}/m2m/{targetService}/credentials
tenants/{env}/{tenantId}/{module}/kafka
clusters/{env}/{dbType}/{service}/shared/admin          <- production only
clusters/{env}/{dbType}/shared/admin                    <- every other environment
clusters/{env}/{dbType}/{service}/dedicated/{tenantOrgID}/admin
```

**`{env}` here is the APPLICATION's environment name, not this repository's.** The
naming module validates `environment` against the closed enum `dev|stg|prd`, while
the vault paths carry whatever `ENV_NAME` the application boots with — `production`
on the consignado estate. They are different namespaces in the same account and they
do not collide, but writing `prd` into `secret_path_prefixes` produces a policy that
matches nothing and a pod that gets AccessDenied on every read.

**The env segment is optional in the builder.** `lib-commons` emits
`tenants/{tenantOrgID}/...` with no env segment when the environment string is blank
(`commons/secretsmanager/external.go:92-95`), and several tenant-manager provisioning
handlers pass it blank. A prefix of `tenants/production/` does not match that
degenerate form. Decide whether to cover it deliberately; do not discover it.

## KMS

`CreateSecret` on an account with no default CMK still needs `kms:GenerateDataKey`
and `kms:Decrypt` against `aws/secretsmanager`, and reading a secret encrypted with a
customer managed key needs `kms:Decrypt` on that key. Pass `kms_key_arns` when either
applies. Left empty, the module emits no KMS statement — correct for a caller that
only reads AWS-managed-key secrets.
