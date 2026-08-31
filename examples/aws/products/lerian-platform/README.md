# `lerian-platform`

Cluster-level roots that belong to no product.

| Root | What it provisions |
|---|---|
| `dns` | Public hosted zone + wildcard ACM certificate |
| `eso` | IRSA for External Secrets Operator |

## Why a pseudo-product under `products/`

`lerian-infra` discovers roots by walking `products/*/*` and nothing else, and its
`infra-base` stage is hardcoded to exactly `vpc` and `eks`
(`pkg/infra/discover.go:36-78`, `:128-153`). A root at `infra-base/dns` would be
invisible to the CLI: no ordering, no account guard, no derived state key — applied
by hand or not at all. Living here buys all three, at the cost of a name that reads
like a product and is not one.

Both roots run in the products stage, which is after `infra-base/eks`. Neither is
depended on by any product root, so their position in the alphabetical product order
does not matter.

## `dns` has the only manual step on the estate

The parent domain lives in a different AWS account. This root creates the child zone
and emits its four name servers; somebody creates **one** NS record in the parent.
The ACM certificate cannot validate until that exists, so the apply *blocks* — which
is the intended shape. A certificate that silently "succeeded" without validation
fails later at the ALB, where it is much harder to read.

## `eso` is what makes every other credential usable

Every datastore module in this repository generates a strong password and writes it
to Secrets Manager, and none of them delivers it to a pod. Apply the whole estate
without ESO and every workload boots without its database password.

It is **read-only** and account-wide: no `CreateSecret`, no `PutSecretValue`, no
`DeleteSecret`. A compromise of the operator reads credentials and cannot destroy
them.

**Its `kms_key_arns` is not optional once MSK exists.** AWS refuses an AWS-managed
key on a secret associated with an MSK cluster, so the MSK module creates its own
CMK. Without `kms:Decrypt` on it the SASL password never projects, and the
ExternalSecret sits in `SecretSyncedError` while everything else syncs.

## Kafka topics — owned here, created by Helm

Terraform creates no topic and cannot: `auto.create.topics.enable` is false by
design, and the foundation's position (`_modules/streaming-msk`) is that topic
provisioning is an environment concern. The consignado wire needs, at minimum:

| Topic | Producer | Consumer |
|---|---|---|
| `lerian.streaming.consignado-gw` | br-consignado-gw | streaming-hub |
| `lerian.streaming.consignado-gw.dlq` | streaming-hub (DLQ plane) | streaming-hub |
| `lerian.streaming.lender.commands` | lender | br-consignado-gw (group `br-consignado-gw.lender-commands`) |

and, when lender lands, `lerian.streaming.lender` plus `lerian.streaming.lender.dlq`.

Create them with an `rpk topic create` Job in the helmfile phase, with explicit
partition and replication settings — the broker default
(`default_replication_factor`) is otherwise what the fact stream inherits.
