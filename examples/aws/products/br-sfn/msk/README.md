# products/br-sfn/msk

Kafka for the br-sfn SFN rails monorepo. Root stack over
[`_modules/streaming-msk`](../../../_modules/streaming-msk).

One root, one datastore, one state file. See [`../README.md`](../README.md) for
the product-level picture: deploy order, the shared-vs-dedicated model, and the
full Helm mapping.

| | |
|---|---|
| Module | `../../../_modules/streaming-msk` |
| State key | `aws/products/br-sfn/msk/terraform.tfstate` |
| Creates | `br-sfn-{env}-msk` (MSK cluster) |
| Secret | `AmazonMSK_br-sfn-{env}-msk` — **not** the usual `{name}/password` |
| Chart target | **none the chart names** — `helm_values` is empty, see below |
| Chart verified | br-sfn 1.1.0, appVersion `1.0.0-beta.1` |

## Read this first: the chart names no streaming variable

**A grep for `STREAMING`, `KAFKA`, `REDPANDA` or `BROKER` over the entire br-sfn
chart returns only prose.** No variable, on any rail:

| Where | What it says |
|---|---|
| `Chart.yaml:43-45` | *"Postgres, Valkey/Redis, RabbitMQ, RedPanda and IBM MQ are EXTERNAL, pre-provisioned services"* |
| `README.md:40-42` | the four SPI components *"ride one Postgres, one Redis and one RedPanda"* |
| `README.md:78-79` | *"RedPanda topics for spb/spi are an environment concern (the compose `redpanda-topics` one-shot is dev-only)"* |
| `templates/common/NOTES.txt:30` | the same infra contract, restated |

So the chart confirms that a Kafka API is consumed by `spb` and `spi`, and
confirms **nothing** about how it is configured. That is not a chart bug:
br-sfn has no fixed env allowlist — `<component>.configmap` and
`<component>.secrets` are emitted **verbatim** (`README.md:66-72`) — so the
variable names live in the br-sfn application repository, not in the chart.

> **CONFIRMAR no chart:** the streaming env var names read by the `spb` and `spi`
> rails — the broker list, the TLS switch, the SASL mechanism/username keys.
> Two shapes exist in the fleet and they are **not** compatible:
>
> | Chart | Shape |
> |---|---|
> | br-sisbajud | `STREAMING_BROKERS`, `STREAMING_TLS_ENABLED`, `STREAMING_SASL_MECHANISM`, `STREAMING_SASL_USERNAME`, `STREAMING_SASL_PASSWORD` |
> | midaz | `STREAMING_ENABLED` only — **no broker variable at all** |
>
> br-sfn may use either, both or neither. Ask the br-sfn service owners; do not
> infer it from a sibling chart.

### `helm_values` is empty, on purpose

Emitting a guessed key here would be **actively harmful**. Because the chart
passes component configmaps through untouched, a wrong name lands in the
ConfigMap with no error at all, and the rail falls back to whatever default it
compiles in — a broker list pointing nowhere, discovered in production.

The values are all here; only the key names are missing:

| Output | Value |
|---|---|
| `endpoint` | the bootstrap broker list, `host:port,host:port,...` |
| `port` | `9096` with SASL/SCRAM on |
| `scram_username` | the SASL username (published as an output here precisely because `helm_values` is empty) |
| `secret_name` | `AmazonMSK_br-sfn-{env}-msk` → the SASL password, via External Secrets |

and the mechanism is **`SCRAM-SHA-512`**, the only one MSK offers.

## Topics: nothing creates them

br-sisbajud ships an ArgoCD PreSync Job that runs `rpk topic create`. **br-sfn
ships nothing** — it explicitly calls topics an environment concern and notes
that the compose `redpanda-topics` one-shot is dev-only.

So something outside both the chart and this Terraform has to create the topics
before the rails publish. `auto_create_topics_enable` stays **false** anyway,
matching every other Lerian cluster: with auto-create on, the first publish
silently produces a topic with broker defaults — wrong partition count, wrong
replication factor, wrong retention — and a typo in a topic name becomes a live
topic instead of an error.

`default_replication_factor` matters more here than elsewhere for the same
reason: nothing creates topics with an explicit factor, so whatever eventually
does will very likely inherit the broker default. It derives `min(brokers, 3)`,
which is 3 on every cluster this root creates.

## Read this before applying: prefer `mode = "shared"`

**A dedicated MSK cluster is the most expensive thing in this product, by an
order of magnitude.**

MSK has no cheap corner, and the reason is the broker count rather than the
broker size:

- `kafka.t3.small` is the smallest broker AWS offers.
- The minimum is two brokers.
- The broker count must be a **multiple of the number of client subnets**, and
  `infra-base/vpc` tags **three** subnets `Type=database`.

Valid values are 3, 6, 9 and the real floor is **three brokers, roughly
USD 105/month**, per product, before a single message is published.

```
mode = "shared"      -> resolve shared-{env}-msk. Zero resources, zero cost.
mode = "dedicated"   -> br-sfn-{env}-msk. ~USD 105/month minimum.
```

### What could justify `dedicated`, and why the evidence is thin

**Regulatory isolation.** br-sfn talks directly to BACEN and Nuclea over RSFN —
SPB/STR settlement, SPI/Pix, SILOC, SCR. A shared Kafka cluster is one topic
namespace, one set of ACLs and one retention budget for every product pointed at
it. If the deployment has to be able to state that no other workload can read or
replay that traffic, that is the argument.

**But note how much weaker the chart-side evidence is than br-sisbajud's.**
br-sisbajud defaults `STREAMING_ENABLED` to `"true"` and marks
`STREAMING_BROKERS` REQUIRED — a broker is unambiguously mandatory there. br-sfn
names nothing, so even *whether this deployment needs a broker at all* depends on
which rails are enabled and on application facts the chart does not carry.

Confirm with the br-sfn service owners before provisioning either mode.

## Run it

```bash
cd examples/aws/products/br-sfn/msk

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/br-sfn/msk/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

`../../../` is **three** levels up and lands on `examples/aws`, where both
`backend/` and `_modules/` live. Verified with `terraform init`.

Prerequisites in `dedicated` mode: `infra-base/vpc`. `infra-base/eks` is optional
at apply time. In `shared` mode: `products/shared-resources/msk`, and nothing
else.

## Ingress

Handled by [`_modules/product-network`](../../../_modules/product-network),
called here as `module.network` with `enabled = var.mode == "dedicated"`. Two
sources, merged and handed to `streaming-msk`:

- **`Type=private` subnet CIDRs** (`allow_private_subnet_cidr_ingress`, default
  true). Depends only on `infra-base/vpc`.
- **the EKS node security group**, matched by `tag:Name = "lerian-{env}-eks-node"`
  with the **plural** `data "aws_security_groups"`, so an absent cluster returns
  an empty list rather than failing the plan.

> `var.subnet_tag_type` (`"database"`) selects the **client subnets the brokers
> are placed in** and goes to `streaming-msk` only, alongside `var.subnet_ids`.
> `product-network` keeps its own default (`"private"`), the subnets whose CIDRs
> become **ingress**.

Rules are opened only on the listener ports the enabled authentication modes use
— 9096 for SASL/SCRAM, 9094 for TLS, 9092 for plaintext.

The "nothing can reach this cluster at all" case is **not** re-asserted here: the
module carries `check "ingress_is_reachable"`. That check exists because of MSK
specifically — the module used to ship no VPC-CIDR fallback, so two empty allow
lists produced a cluster that looked healthy and accepted no connections.

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
This one writes **`AmazonMSK_br-sfn-{env}-msk`**, with no path segment.

That is an AWS requirement: `aws_msk_scram_secret_association` rejects any secret
whose name does not start with `AmazonMSK_`, and additionally requires it to be
encrypted with a **customer managed** CMK. The module creates that second CMK
(`scram_kms_key_arn`) for exactly this reason.

`var.shared_secret_name` on the module validates the prefix at plan time. This
root does not re-expose it — see *Shared mode*.

## Outputs

Seven uniform contract names shared with every other Lerian datastore root —
`mode`, `endpoint`, `port`, `security_group_id`, `secret_arn`, `secret_name`,
`identifier` — plus `bootstrap_brokers*`, `cluster_arn`, `cluster_uuid`,
`configuration_arn`, `kms_key_arn`, `scram_kms_key_arn`, `log_group_arn`,
`zookeeper_connect_string`, `scram_username`, the cross-stack context, and
`helm_values` (empty).

Two of the seven mean something different here, and both differences are real:

- **`endpoint` is a comma separated bootstrap broker LIST**, not a host. A Kafka
  client bootstraps from several brokers. This is also why MSK never had a
  private CNAME to remove: there was no single host to alias.
- **`secret_name` carries the `AmazonMSK_` prefix**, as above.

## Shared mode

`mode = "shared"` creates nothing and plans to zero resources. Every lookup in
this root is gated on `mode == "dedicated"`, so the VPC does not even need to
exist. The module resolves the cluster `shared-{env}-msk` with
`data "aws_msk_cluster"` and the secret `AmazonMSK_shared-{env}-msk` with
`data "aws_secretsmanager_secret"`. `security_group_id` comes back `null`:
opening the shared cluster is `products/shared-resources/msk`' job.

Both names are fully derived, so this root exposes no variable for either. The
module's own `shared_secret_name` is the escape hatch for a secret created
outside this Terraform, and it validates the `AmazonMSK_` prefix.

Every sizing variable in the tfvars is ignored in that mode.

> On a shared cluster the topic-namespace collision risk is real, and br-sfn is
> the product most exposed to it: nothing creates its topics, so nothing enforces
> a naming prefix either. Agree one before pointing `spb` and `spi` at the shared
> tier.

## IBM MQ is not here

The chart's infra contract lists **IBM MQ** alongside RedPanda as an external
service (`Chart.yaml:43-45`) — it is the SPB/STR rail's messaging transport, and
the reason the `spb` image is CGO/debian rather than distroless. AWS offers no
managed IBM MQ, so this repository provisions none: it is an external dependency
of the deployment. See [`../README.md`](../README.md).
