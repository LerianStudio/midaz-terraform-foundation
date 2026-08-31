# `products/lerian-platform/eso`

IRSA for External Secrets Operator — the stack that makes every other credential in
this repository usable.

Every datastore module generates a strong password and writes it to Secrets Manager.
None of them delivers it to a pod. Apply the whole estate without this and every
workload boots without its database password.

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
