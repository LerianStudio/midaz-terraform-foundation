# `products/br-consignado-gw/secrets`

The custody identity. The gateway holds each tenant's **Dataprev credential**.

## The reference format, and why it is permanent

```
tenants/{env}/{tenantOrgID}/br-consignado-gw/external/{target}/credentials/versions/{uuid}
```

with `{target}` one of `dataprev-cert` or `dataprev-oauth` — two values on purpose,
so rotating the certificate can never overwrite the OAuth secret.

On read the gateway **re-parses the stored reference and demands exact scope
equality**. A credential written under one environment name becomes unreadable the
day that name changes. On this estate `{env}` is **`production`** from the first
write, in both accounts, forever. Note that `var.environment` here is `prd`: the
repository's environment vocabulary names the IAM objects, the application's
`ENV_NAME` names the vault path. They differ, and the difference is load-bearing.

## `CreateSecret` and `DeleteSecret`, never `PutSecretValue`

A version is immutable: the gateway stages a new secret at a new version path and
never overwrites an old one. `DeleteSecret` rolls a failed staging back. Granting
`PutSecretValue` would make the custody audit trail rewritable by the service that
is supposed to be audited — a variable validation refuses it rather than merely
omitting it.

## No `ListSecrets`

The gateway reads by exact reference and enumerates nothing. Since `ListSecrets`
cannot be resource-scoped, leaving it off is a real narrowing.

## Nothing here puts a credential in the vault

The IaC delivers the role. The **tenant** writes the credential through the
gateway's own custody API, with an audit trail. No operator handles a Dataprev
credential and none appears in any file in this repository.
