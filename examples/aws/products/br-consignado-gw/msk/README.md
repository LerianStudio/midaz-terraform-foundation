# `products/br-consignado-gw/msk`

Resolves the Kafka cluster the gateway publishes the consignado fact stream to.
**Default mode is `shared`, and that is correctness rather than thrift** — see
`../../streaming-hub/msk/README.md` for the consumer half of the same argument.

## Topics

| Direction | Topic |
|---|---|
| produces | `lerian.streaming.consignado-gw` (all 21 fact definitions ride one route) |
| DLQ | `lerian.streaming.consignado-gw.dlq` |
| consumes | `lerian.streaming.lender.commands`, group `br-consignado-gw.lender-commands` |

Nothing creates them. See `../../lerian-platform/README.md`.

## The SASL credentials are FILE PATHS, not values

`STREAMING_KAFKA_SASL_USERNAME_FILE` and `_PASSWORD_FILE` are read from disk at
boot, as is `STREAMING_KAFKA_TLS_CA_FILE`. A chart that projects the SASL credential
as an environment variable — which is what every other service on this estate does —
produces a gateway that cannot authenticate to Kafka. It needs a **mounted volume**
from the projected secret.

The paths themselves are a chart decision and are deliberately not emitted in
`helm_values`: a path Terraform cannot guarantee exists is worse than no path.

## Managed deployments fail closed

A managed deployment refuses to boot unless TLS is on, plaintext is off, the
mechanism is a SCRAM variant and **both** credential files are set. MSK offers
SCRAM-SHA-512 only.
