# products/br-sisbajud/msk

Kafka for the br-sisbajud SISBAJUD plugin. Root stack over
[`_modules/streaming-msk`](../../../_modules/streaming-msk).

One root, one datastore, one state file. See [`../README.md`](../README.md) for
the product-level picture: deploy order, the shared-vs-dedicated model, and the
full Helm mapping.

| | |
|---|---|
| Module | `../../../_modules/streaming-msk` |
| State key | `aws/products/br-sisbajud/msk/terraform.tfstate` |
| Creates | `br-sisbajud-{env}-msk` (MSK cluster) |
| Secret | `AmazonMSK_br-sisbajud-{env}-msk` — **not** the usual `{name}/password` |
| Chart target | `brSisbajud.configmap` (`STREAMING_*`) |
| Chart verified | br-sisbajud 1.1.0, appVersion `1.0.0-beta.109` |

## Read this before applying: prefer `mode = "shared"`

**A dedicated MSK cluster is the most expensive thing in this product, by an
order of magnitude.**

MSK has no cheap corner, and the reason is the broker count rather than the
broker size:

- `kafka.t3.small` is the smallest broker AWS offers.
- The minimum is two brokers.
- The broker count must be a **multiple of the number of client subnets**, and
  `infra-base/vpc` tags **three** subnets `Type=database`.

So the valid values are 3, 6, 9 and the real floor is **three brokers, roughly
USD 105/month**, per product, before a single message is published. For scale:
the whole rest of br-sisbajud (`db.t4g.micro` Postgres plus `cache.t4g.micro`
Valkey) is about USD 27/month.

```
mode = "shared"      -> resolve shared-{env}-msk. Zero resources, zero cost.
mode = "dedicated"   -> br-sisbajud-{env}-msk. ~USD 105/month minimum.
```

`shared` is the normal choice. `dedicated` needs an argument.

### The argument that would justify `dedicated` here

**Regulatory isolation, not cost or throughput.** A shared Kafka cluster is one
topic namespace, one set of ACLs and one retention budget for every product
pointed at it. br-sisbajud carries judicial asset blocking and unblocking ordered
through BACEN SISBAJUD: `br-sisbajud.block_account.created`,
`br-sisbajud.kek.rotated` and the balance events behind them. If the deployment
has to be able to state that no other workload can read or replay those events,
that is an isolation requirement and a dedicated cluster is how it is met.

**Note what the chart does *not* say.** br-sisbajud is the most
streaming-committed chart in the fleet — `STREAMING_ENABLED` defaults to `"true"`
and `STREAMING_BROKERS` is marked `REQUIRED`
(`values-template.yaml:23-24`), and the README states that *"a producer with
`STREAMING_ENABLED=true` and empty `STREAMING_BROKERS` fails closed at boot by
design"*. That makes a broker **mandatory**. It does not make a *dedicated*
broker mandatory. Nothing in the chart, its values or its upgrade docs asks for
one. Treat the isolation argument as a deployment decision to be made and
recorded, not as something the chart already decided.

## Topics are NOT managed by Terraform

This is the single most important operational fact about this directory.

The chart ships an **ArgoCD PreSync Job** (`templates/topics/job.yaml`) running
the `br-sisbajud-topics` image, which executes `rpk topic create` (list-then-create,
idempotent) for six topics declared in `values.yaml:178-184`:

| Topic | DLQ sibling |
|---|---|
| `br-sisbajud.ledger.balance.changed` | `br-sisbajud.ledger.balance.changed.dlq` |
| `br-sisbajud.block_account.created` | `br-sisbajud.block_account.created.dlq` |
| `br-sisbajud.kek.rotated` | `br-sisbajud.kek.rotated.dlq` |

`midaz.balance.changed` is deliberately **absent** from that list: Midaz owns and
creates it, br-sisbajud only consumes it (`values.yaml:165-166`).

The Job runs at `hook-weight: -1`, the same wave as the migration Job and before
the Deployment, so the balance translator never halt-loops on
`UNKNOWN_TOPIC_OR_PARTITION` and DLQ publishes never fail on a fresh broker.

Consequences for this Terraform:

- `auto_create_topics_enable` stays **false**. With it on, a typo in a topic name
  would create a live topic with broker defaults instead of failing loudly.
- Terraform provisions the cluster, the credentials and the ingress. It does not
  know the topic set and must not create it.

> **`topics.replicationFactor` defaults to `1` in the chart** (`values.yaml:176`,
> commented *"per-env; 3 on multi-broker prod"*). Every cluster this root creates
> has at least three brokers, so leaving it at 1 means every SISBAJUD topic
> survives on a single broker and a routine broker replacement loses partitions.
> Set it to 3 in the release values. Terraform's `default_replication_factor` is
> the **broker** default and only applies to topics created *without* an explicit
> factor — `rpk topic create` passes one, so it does not cover this.

## Run it

```bash
cd examples/aws/products/br-sisbajud/msk

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/br-sisbajud/msk/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

`../../../` is **three** levels up and lands on `examples/aws`, where both
`backend/` and `_modules/` live. Verified with `terraform init`.

Prerequisites in `dedicated` mode: `infra-base/vpc`. `infra-base/eks` is optional
at apply time — see *Ingress* below. In `shared` mode:
`products/shared-resources/msk`, and nothing else.

## Ingress

Handled by [`_modules/product-network`](../../../_modules/product-network),
called here as `module.network` with `enabled = var.mode == "dedicated"`. Two
sources, merged and handed to `streaming-msk`:

- **`Type=private` subnet CIDRs** (`allow_private_subnet_cidr_ingress`, default
  true). Depends only on `infra-base/vpc`, so it works from the first apply.
- **the EKS node security group**, matched by `tag:Name = "lerian-{env}-eks-node"`
  with the **plural** `data "aws_security_groups"`, so an absent cluster returns
  an empty list rather than failing the plan.
  `check "eks_node_security_group_resolved"` warns while it is empty.

> `var.subnet_tag_type` (`"database"`) selects the **client subnets the brokers
> are placed in** and goes to `streaming-msk` only, alongside `var.subnet_ids`.
> `product-network` keeps its own default (`"private"`), the subnets whose CIDRs
> become **ingress**. Do not forward one into the other.

Rules are opened only on the listener ports the enabled authentication modes
actually use — 9096 for SASL/SCRAM, 9094 for TLS, 9092 for plaintext — never on a
whole protocol.

The "nothing can reach this cluster at all" case is **not** re-asserted here: the
module carries `check "ingress_is_reachable"`. That check exists because of MSK
specifically: the module used to ship no VPC-CIDR fallback at all, so two empty
allow lists produced zero ingress and a cluster that looked healthy and accepted
no connections.

## Sizing traps

| Trap | Consequence | Where it is caught |
|---|---|---|
| `number_of_broker_nodes` not a multiple of the client subnet count | AWS rejects the cluster | Module precondition, at **plan** time |
| `number_of_broker_nodes = 2` with three `Type=database` subnets | same | same — narrow `subnet_ids` to two subnets first |
| `storage_mode = "TIERED"` on `kafka.t3.*` | the family does not support tiered storage | Apply |
| `enable_sasl_scram` with `encryption_in_transit_client_broker = "PLAINTEXT"` | SASL/SCRAM requires TLS | Module precondition, at **plan** time |
| no authentication mode enabled at all | nothing can connect | Module precondition, at **plan** time |

## The secret does not follow the Lerian naming convention

Every other Lerian datastore writes `{name}/password` or `{name}/auth-token`.
This one writes **`AmazonMSK_br-sisbajud-{env}-msk`**, with no path segment.

That is an AWS requirement, not a choice: `aws_msk_scram_secret_association`
rejects any secret whose name does not start with `AmazonMSK_`, and additionally
requires it to be encrypted with a **customer managed** CMK. The module creates
that second CMK (`scram_kms_key_arn`) for exactly this reason.

`var.shared_secret_name` on the module validates the prefix at plan time so an
override cannot silently produce an unusable name. This root does not re-expose
it — see *Shared mode*.

## Outputs

Seven uniform contract names shared with every other Lerian datastore root —
`mode`, `endpoint`, `port`, `security_group_id`, `secret_arn`, `secret_name`,
`identifier` — plus `bootstrap_brokers*`, `cluster_arn`, `cluster_uuid`,
`configuration_arn`, `kms_key_arn`, `scram_kms_key_arn`, `log_group_arn`,
`zookeeper_connect_string`, the cross-stack context, and `helm_values`.

Two of the seven mean something different here, and both differences are real:

- **`endpoint` is a comma separated bootstrap broker LIST**, not a host. A Kafka
  client bootstraps from several brokers. This is also why MSK never had a
  private CNAME to remove: there was no single host to alias.
- **`secret_name` carries the `AmazonMSK_` prefix**, as above.

```bash
terraform output -json helm_values | jq
```

## Helm handoff

**br-sisbajud is the one Lerian chart with a complete streaming contract.** Do
not reason about it from `products/shared-resources/msk`, whose header documents
the midaz gap (midaz has no `STREAMING_BROKERS` at all and needs
`extraEnvVars`).

| Terraform | Chart env var | Notes |
|---|---|---|
| literal `"true"` | `STREAMING_ENABLED` | chart default; echoed, not decided here |
| `endpoint` | `STREAMING_BROKERS` | marked **REQUIRED**; empty fails closed at boot |
| derived | `STREAMING_TLS_ENABLED` | tracks the listener the bootstrap list points at |
| literal `"SCRAM-SHA-512"` | `STREAMING_SASL_MECHANISM` | only when `enable_sasl_scram` |
| `scram_username` | `STREAMING_SASL_USERNAME` | only when `enable_sasl_scram` |
| `secret_name` → External Secrets | `STREAMING_SASL_PASSWORD` | never an output |

Verified against `values-template.yaml:23-25` and `templates/topics/job.yaml:27-32`
— the topics Job declares the full set it resolves from `extraEnvVars` then
`configmap`, which is the authoritative list of names.

**`SCRAM-SHA-512` is not a preference.** SASL/SCRAM on MSK is SCRAM-SHA-512 only;
SCRAM-SHA-256 is not offered. The chart's own upgrade doc uses SHA-256 as its
example (`docs/UPGRADE-1.1.md:122`), which would fail to authenticate against
MSK — the mechanism is emitted here precisely so nobody copies that example.

**The SASL keys are omitted, not emptied,** when `enable_sasl_scram` is false.
The topics Job renders the optional `STREAMING_SASL_*` keys only when they carry
a value (`templates/topics/job.yaml:39-42`), so an empty string is not equivalent
to an absent key: it would make `rpk` attempt a SASL handshake with no mechanism.

`STREAMING_TLS_CA_CERT` is **not** emitted: MSK broker certificates chain to the
public Amazon trust store, so no bundle needs distributing.
`STREAMING_CLOUDEVENTS_SOURCE` is not emitted either — it is an application
identity (`br-sisbajud`), not an infrastructure fact, and the chart already
defaults it correctly.

## Shared mode

`mode = "shared"` creates nothing and plans to zero resources. Every lookup in
this root is gated on `mode == "dedicated"`, so the VPC does not even need to
exist. The module resolves the cluster `shared-{env}-msk` with
`data "aws_msk_cluster"` and the secret `AmazonMSK_shared-{env}-msk` with
`data "aws_secretsmanager_secret"`; the bootstrap lists, the port, the cluster
ARN and the UUID then come from the resolved cluster.
`security_group_id` comes back `null`: opening the shared cluster is
`products/shared-resources/msk`' job, and a product cannot authorise itself onto
it.

Both names are fully derived, so this root exposes no variable for either. The
module's own `shared_secret_name` is the escape hatch for a secret created
outside this Terraform, and it validates the `AmazonMSK_` prefix.

Every sizing variable in the tfvars is ignored in that mode.

> On the shared tier the topic-name collision risk stops being theoretical: two
> products creating topics from their own PreSync Jobs share one namespace. The
> `br-sisbajud.` prefix on all six topics is what keeps that safe here.
