# `streaming-hub`

The event delivery edge: it consumes CloudEvents off Kafka and fans them out per
tenant to webhooks, SQS, RabbitMQ and EventBridge.

| Root | What it provisions | Mode |
|---|---|---|
| `postgres` | The hub's only mandatory datastore | `dedicated` |
| `msk` | Resolves the Kafka the producers publish to | **`shared`** |
| `secrets` | IRSA for the tenant roster listing | n/a |

## What it does NOT need, measured

- **No Valkey/Redis.** Removed deliberately: cron singleton-ing uses
  `pg_try_advisory_xact_lock` and idempotency is a durable Postgres store, both so
  a BYOC deployment need not run Redis.
- **No DocumentDB, no S3, no KMS.** SQS, EventBridge and RabbitMQ appear in the
  dependency list as *customer-owned delivery sinks*, reached with credentials that
  arrive per subscription from the decrypted database config. Provision none of them.

## Three things that bite

**`msk` must be `shared`.** The hub subscribes by regex — `^lerian\.streaming\.<app>$`
— so it can only see what a producer wrote to the *same cluster*. A dedicated broker
gives a healthy pod that consumes nothing, and an empty regex match is not a failure
condition anywhere in Kafka.

**The KEK is not a Secrets Manager dependency, despite appearances.**
`STREAMING_HUB_KEK_SOURCE` accepts the literal `secretsmanager`, and both that value
and `env` resolve through the same environment-variable source with no AWS SDK
involved. What the KEK needs is an ExternalSecret projecting it as an env var. An
empty KEK makes the hub *refuse to sign* webhooks rather than degrade.

**`ListSecrets` is load-bearing and unscopeable.** In multi-tenant mode the roster
IS the vault listing, an empty listing refuses the boot, and AWS does not evaluate
`ListSecrets` against a resource. Grant it to every hub pod, not only ingest.

## Topics

Nothing here creates them. `auto.create.topics.enable` is false and the set is
whatever `ce-source` values the producers use. See `../lerian-platform/README.md`
for the list this estate needs and where the `rpk` Job lives.
