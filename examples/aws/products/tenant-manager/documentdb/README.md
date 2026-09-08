# `products/tenant-manager/documentdb`

The control plane's own datastore. Holds tenants, services and *references* to
secrets — never a secret itself.

## `documentdb_tls = "enabled"`, unlike every other DocumentDB tfvars here

The foundation ships `"disabled"` in all three environments, labelled a KNOWN GAP,
because the blocker is the RDS CA bundle Terraform does not distribute.

tenant-manager is not blocked by it: `MONGODB_TLS=true` makes the service append
`tls=true&tlsInsecure=true`, skipping verification deliberately because DocumentDB
presents Amazon's own CA and there is no env var for a bundle.

Be precise about what that buys: the traffic is **encrypted** and the server is
**not authenticated**. Inside a private subnet whose only clients are the cluster's
nodes that is a real improvement on plaintext, and it is not verified TLS.

## `retryWrites=false` must be in the URI string

The service appends it only to the tenant URIs it provisions, never to its own.
DocumentDB does not implement retryable writes and the driver enables them by
default, so a URI without it fails on the first write with an error naming neither
DocumentDB nor the option. The URI is composed in an ExternalSecret template — see
the `mongodb_uri_template_hint` output.
