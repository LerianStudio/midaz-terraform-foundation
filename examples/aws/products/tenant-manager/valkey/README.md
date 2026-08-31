# `products/tenant-manager/valkey`

Cache and idempotency store for the control plane.

## `required` + auth token, unlike every other Valkey tfvars here

The foundation ships `transit_encryption_mode = "preferred"` with no auth token,
labelled a KNOWN GAP, and the reason is real: most Lerian charts have nowhere to put
a Redis password or a CA bundle.

tenant-manager does. It reads `REDIS_TLS`, `REDIS_PASSWORD` and `REDIS_CA_CERT`, and
the CA is **base64-encoded PEM, not a file path**, so External Secrets delivers it
as a value with nothing mounted.

`"preferred"` is not weaker TLS, it is *optional* TLS — the server accepts a
plaintext client. On a store that caches admin credential lookups for the whole
estate, that is not a posture to inherit without arguing with it.

## Leave `REDIS_USERNAME` unset

ElastiCache auth tokens are the legacy password-only AUTH, which has no username.
The service branches on `REDIS_USERNAME` being non-empty onto a direct go-redis ACL
client that sends `AUTH <user> <token>`; the server rejects it. Setting the variable
"for completeness" breaks the connection.
