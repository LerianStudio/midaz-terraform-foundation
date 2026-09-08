# `products/streaming-hub/msk`

Resolves the Kafka cluster streaming-hub consumes from. **Default mode is `shared`,
and that is correctness rather than thrift.**

The hub subscribes by regex, `^lerian\.streaming\.<app>$`, so it can only ever see
what a producer wrote to the *same* cluster. Point it at a dedicated broker and it
subscribes successfully, reports healthy and consumes nothing — an empty regex match
is not a failure condition, so no error is raised on either side. On the consignado
wire the producer is `br-consignado-gw`; both roots must resolve `shared-{env}-msk`.

In shared mode this root plans zero resources.

## What it hands over

`STREAMING_HUB_KAFKA_BROKERS`, `_TLS_ENABLED` and `_SCRAM_MECHANISM`. Note the
`STREAMING_HUB_` prefix: the unprefixed `STREAMING_*` names are lib-streaming's
*producer* surface and this service does not read them. The SCRAM username and
password are omitted on purpose — they are required together, the service fails
closed with only one, and both arrive from the vault via External Secrets.

`scram_kms_key_arn` feeds `products/lerian-platform/eso`. Without it the password
never projects.

## Consumer groups, for the Kafka ACL

`streaming-hub.{STREAMING_HUB_ENV}` and `streaming-hub-dlq.{STREAMING_HUB_ENV}`,
both LITERAL READ + DESCRIBE, plus PREFIXED READ + DESCRIBE on `lerian.streaming.`.
The grant is read-only: the hub produces nothing to Kafka. ACLs are created against
the cluster by tenant-manager over the Kafka wire protocol, not by Terraform and not
by IAM.

## Topics

Not created here and not creatable here — there is no fixed list, only a regex over
whatever the producers publish. See `../../lerian-platform/README.md`.
