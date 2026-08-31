# `products/lerian-platform/eso`

IRSA for External Secrets Operator — the stack that makes every other credential in
this repository usable.

Every datastore module generates a strong password and writes it to Secrets Manager.
None of them delivers it to a pod. Apply the whole estate without this and every
workload boots without its database password.

## The prefix list has two naming families, and missing one is silent

The application secrets live under `tenants/` and `clusters/`. The credentials **this
repository generates** do not:

| Shape | Written by |
|---|---|
| `{product}-{env}-postgres/password` | `_modules/postgres-rds/main.tf:255` |
| `{product}-{env}-valkey/auth-token` | `_modules/valkey-elasticache/main.tf:226` |
| `{product}-{env}-docdb/password` | `_modules/mongodb-documentdb/main.tf:177` |
| `AmazonMSK_{name}` | `_modules/streaming-msk/main.tf:88-92` |

And a fourth, written by hand: `installation/{env}/...`, whose only inhabitant today
is the streaming-hub KEK. Grant it before the secret exists — an empty namespace
costs nothing, and deferring the grant is how the KEK ends up unreadable with the hub
reporting healthy and refusing to sign.

A list covering only the first family produces an operator that syncs every
application secret and **not one database password**. The symptom is
`SecretSyncedError` on exactly the ExternalSecrets the estate cannot boot without —
and it looks identical to a missing KMS grant, so check the prefixes first.

`secret_path_prefixes` defaults to empty: the module refuses to build a role whose
read actions have no resource, so an unset list fails the plan rather than producing
an operator that reads nothing.

## The custody path is denied

The broad Allow over `tenants/` would otherwise cover
`tenants/{env}/{org}/{app}/external/.../credentials/versions/{uuid}`. Anyone able to
create an ExternalSecret in any namespace could project a tenant's Dataprev
credential into a Secret they read — read-only stops the operator destroying
credentials and does nothing about exfiltrating one.

`deny_secret_path_patterns = ["tenants/*/*/*/external/"]` closes it. The gateway
reads its own custody store with its own role, so ESO loses nothing.

## Read-only, account-wide

No `CreateSecret`, no `PutSecretValue`, no `DeleteSecret`. A compromise of the
operator reads credentials and cannot destroy them; that asymmetry is the security
value of keeping it a separate role from the services' own.

`ListSecrets` is granted because store validation and find-by-name/find-by-tag
ExternalSecrets enumerate, and AWS does not scope it to a resource.

## `kms_key_arns` is not optional once MSK exists

AWS refuses an AWS-managed key on a secret associated with an MSK cluster, so
`_modules/streaming-msk` creates its own CMK. Without `kms:Decrypt` on it the SASL
password never projects and the ExternalSecret sits in `SecretSyncedError` while
every other secret syncs fine. Take the value from the msk root's
`scram_kms_key_arn` output.

## Two projections on the consignado wire depend on this and nothing else

- **streaming-hub's KEK**, which reaches the pod only as an env var. An empty KEK
  makes the hub refuse to sign webhooks rather than degrade quietly.
- **the MSK SASL password**, which br-consignado-gw reads from a **file path**, so
  it needs a projected volume rather than an env var.

## It installs nothing

The operator, its ClusterSecretStore and every ExternalSecret are Helm, in the next
phase. Terraform's contribution is the role ARN on the operator's ServiceAccount.
