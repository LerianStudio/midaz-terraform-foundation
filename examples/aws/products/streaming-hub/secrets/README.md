# `products/streaming-hub/secrets`

IRSA for the tenant roster.

In multi-tenant mode the hub does not read a tenant list from configuration — it
builds one by **listing** the vault for `tenants/{env}/{tenantId}/{module}/kafka`.
An empty listing is not an empty roster, it is a refusal to boot. So a missing grant
surfaces as a crashloop complaining about tenants, never as a permission error.

It reads **names only** on that path; the one value it fetches is its own M2M
manifest credential.

## Three things to get right

**`ListSecrets` cannot be scoped.** AWS evaluates it against the account, so the
statement carries `Resource: "*"` and the hub learns every secret *name* in the
account and no value. That is the price of the roster.

**Annotate every hub pod, not just ingest.** The roster is built at boot by every
role. Scoping the annotation to one Deployment gives a delivery pod that crashloops
while ingest is healthy — which reads like a delivery bug for a long time.

**The KEK is not here.** It reaches the pod as an environment variable projected by
External Secrets, resolved in-process with no AWS SDK involved, despite
`STREAMING_HUB_KEK_SOURCE` accepting the literal `secretsmanager`. See
`../../lerian-platform/eso`.

Single-tenant BYOC makes zero AWS calls and does not need this root at all.
