# `products/streaming-hub/postgres`

The hub's only mandatory datastore. 23 migrations, no Postgres extensions required
(the init migration is an intentional no-op — keys are application-minted UUIDv7).

## Two things this root does that its siblings do not

**`rds.force_ssl = 1`,** through the `parameters` variable this lane added to every
postgres root. Before it, no root wrapper exposed the module's `parameters` input at
all, so the parameter group was born empty and RDS defaults `force_ssl` to 0 —
every database in the estate accepted plaintext from anything inside its security
group. This makes the *server* refuse; the client still has to ask, and does, in the
DSN.

**Postgres 17,** which is three variables changed together: `engine_version`,
`family` and `major_engine_version`. Changing one fails the apply partway.

## `helm_values` is empty on purpose

The service takes a single `STREAMING_HUB_POSTGRES_DSN` that **contains the
password**, and no output in this repository carries a password. The DSN is
assembled by an ExternalSecret template over the JSON secret this stack writes —
`_modules/postgres-rds` writes RDS credentials as JSON precisely so they can be
templated. `sslmode=require` belongs in that template. See the
`dsn_template_hint` output.

## Connection budget

The hub runs several roles with different pool sizes and the invariant is
`sum(replicas x max_open_conns) <= max_connections`. Exceeding it shows up as
intermittent connection refusals under load, not as a startup error.
