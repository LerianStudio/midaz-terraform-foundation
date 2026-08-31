# products/midaz/rabbitmq

Message broker for the midaz ledger. Root stack over
[`_modules/rabbitmq-amazonmq`](../../../_modules/rabbitmq-amazonmq).

One root, one datastore, one state file. See [`../README.md`](../README.md) for
the product-level picture: deploy order, the shared-vs-dedicated model, and the
full Helm mapping.

| | |
|---|---|
| Module | `../../../_modules/rabbitmq-amazonmq` |
| State key | `aws/products/midaz/rabbitmq/terraform.tfstate` |
| Creates | `midaz-{env}-rabbitmq-single` or `-cluster` (AmazonMQ broker) |
| Secret | `midaz-{env}-rabbitmq/password` |
| Chart target | `ledger.configmap` (`RABBITMQ_*`) |

The CRM deployment has no RabbitMQ variables.

## Run it

```bash
cd examples/aws/products/midaz/rabbitmq

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/midaz/rabbitmq/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

`../../../` is **three** levels up and lands on `examples/aws`, where both
`backend/` and `_modules/` live. Verified with `terraform init`.

Prerequisites: `infra-base/vpc`. `infra-base/eks` is optional at apply time —
see *Ingress* below.

An AmazonMQ broker replacement is the slowest apply of the four midaz datastores.
Per-service state means it never blocks an RDS parameter change — which is the
clearest single argument for the one-root-per-service layout.

## Two things called "mode"

They are unrelated and the confusion is worth pre-empting:

| Variable | Values | Meaning |
|---|---|---|
| `mode` | `dedicated` / `shared` | The **Lerian sharing contract**: does this stack create the broker, or resolve one that already exists? |
| `broker_deployment_mode` | `SINGLE_INSTANCE` / `CLUSTER_MULTI_AZ` | The **AWS topology** of the broker. |

The broker *name* carries the topology suffix (`-single` / `-cluster`); the
secret and the security group never do. That is what lets a consumer resolve the
**secret** without knowing the topology, and what makes a
`SINGLE_INSTANCE -> CLUSTER_MULTI_AZ` migration a side-by-side procedure — see
the module's `docs/UPGRADE-GUIDE.md`. Keep `append_deployment_suffix = true`.
The **broker** lookup is the one that does need the suffix declared — see
*Shared mode* below.

## What this root decides

The module already resolves the VPC and the subnets by itself. This root exists
for three things the module cannot do:

1. **Derive the cross-stack names.** `lerian-{env}-vpc` and `lerian-{env}-eks`.
   Note the `lerian` prefix on both: they belong to `infra-base`, not to midaz.
   That is also why this root does **not** call the `naming` module.
2. **Compute the ingress allow list.**
3. **Translate to the chart**, which for RabbitMQ means splitting the broker URI
   AmazonMQ reports into the scheme/host/port triple the chart wants — see below.

It creates no AWS resource of its own.

## Ingress

Identical to the sibling roots, because it is literally the same code: resolved
by [`_modules/product-network`](../../../_modules/product-network), called here
as `module.network` with `enabled = var.mode == "dedicated"` — `var.mode`, the
Lerian sharing axis, **not** `var.broker_deployment_mode`. `Type=private` subnet
CIDRs plus the EKS node security group, matched by
`tag:Name = "lerian-{env}-eks-node"`; `check "eks_node_security_group_resolved"`
lives in that module and warns while the lookup is empty. See its README for the
plural-data-source rule and the deploy-order window it covers.

> `var.subnet_tag_type` (`"database"`) selects the subnets the **broker is
> placed in** and goes to `rabbitmq-amazonmq` only. `product-network` keeps its
> own default (`"private"`), the subnets whose CIDRs become **ingress**.

The "nothing can reach this broker at all" case is **not** re-asserted here: the
module already carries `check "ingress_is_reachable"` for it.

Ingress is scoped to two ports: AMQPS (5671) and, while
`enable_console_ingress` is true, the management console (443). Turning the
console off does not just hide the web UI — the ledger's
`RABBITMQ_HEALTH_CHECK_URL` targets the management HTTP API on that port, so it
breaks the chart's broker health check too. The exposure is bounded by the
ingress allow list, not by the port list; leave it on.

## `RABBITMQ_HOST` is the raw broker host

Always, in both modes, with no switch to flip.

AmazonMQ for RabbitMQ publishes **no plaintext AMQP listener**. The client always
speaks AMQPS, and the broker's TLS certificate covers `*.mq.{region}.on.aws` and
nothing else, so any alias in front of the broker fails hostname verification.
That leaves exactly one host that works, which is why `helm_values` emits
`endpoint` and this root offers no alternative.

The cost is real and worth stating: replacing the broker changes
`RABBITMQ_HOST`, so a replacement is a Helm values change. `terraform output`
regenerates the value on every deploy, so nothing is hardcoded — but the release
does have to be re-rendered.

`endpoint` is the host alone, with no scheme and no port; `amqp_endpoint` is the
full `amqps://host:5671` URI for clients that want a single connection string.

## The two port variables are named backwards

Not a typo in `outputs.tf`. This is the chart's own convention, and the ledger's
init container reads them this way:

| Chart variable | What it actually holds | Value here |
|---|---|---|
| `RABBITMQ_PORT_HOST` | the AMQP(S) port | `5671` |
| `RABBITMQ_PORT_AMQP` | the management HTTP port | `443` |

(Upstream RabbitMQ defaults are 5672 and 15672; AmazonMQ serves AMQPS on 5671 and
the management API over HTTPS on 443.)

## `RABBITMQ_URI` and `RABBITMQ_PROTOCOL` are schemes

Neither is a URI.

- `RABBITMQ_URI = "amqps"` is **mandatory**. The chart default is `"amqp"`, which
  cannot connect to AmazonMQ at all.
- `RABBITMQ_PROTOCOL = "https"` drives `RABBITMQ_HEALTH_CHECK_URL`. The chart's
  `https` branch deliberately omits the port (`printf "%s://%s"`), which is
  correct for 443.

## Instance types

The RabbitMQ engine accepts **only** the `mq.m5.*` and `mq.m7g.*` families:

```
mq.m5.large   mq.m5.xlarge   mq.m5.2xlarge   mq.m5.4xlarge
mq.m7g.medium mq.m7g.large   mq.m7g.xlarge   mq.m7g.2xlarge
mq.m7g.4xlarge mq.m7g.8xlarge mq.m7g.12xlarge mq.m7g.16xlarge
```

`mq.t2.*` and `mq.t3.*` are **ActiveMQ-only**. AmazonMQ rejects them for RabbitMQ
in *every* deployment mode — `SINGLE_INSTANCE` included — with
`Broker engine type [RabbitMQ] does not support host instance type [...]`. The
module catches this with a plan-time precondition. (Earlier revisions of this repo
defaulted dev to `mq.t3.micro` and only guarded it under `CLUSTER_MULTI_AZ`, so
the dev apply failed against a real account.)

Every type in that list supports **both** deployment modes, so the topology never
narrows the choice. `mq.m7g.medium` is the smallest RabbitMQ type there is, which
is why dev uses it.

That is why dev is `SINGLE_INSTANCE` and stg/prd are `CLUSTER_MULTI_AZ`: the
saving in dev is the **node count** — one broker instead of three — not a cheaper
instance type, because AmazonMQ has no cheap RabbitMQ type to offer.

## Users and passwords

The module creates **one** broker user (`mq_admin_user`). The chart wants two —
`RABBITMQ_DEFAULT_USER` (producer) and `RABBITMQ_CONSUMER_USER` (consumer). A
separate consumer user is created on the broker itself, outside Terraform; until
then the admin user serves both roles, and only `RABBITMQ_DEFAULT_USER` is
emitted.

`RABBITMQ_DEFAULT_PASS` and `RABBITMQ_CONSUMER_PASS` are marked `required` by the
chart and **fail the install when empty**. Wire them from `secret_name` through
External Secrets before the first release.

`RABBITMQ_VHOST` is not emitted. AmazonMQ creates the default `/` vhost, but
which vhost the ledger should use is a chart decision, and the chart default is
`""`.

## Outputs

Seven uniform contract names shared with every other Lerian datastore root —
`mode`, `endpoint`, `port`, `security_group_id`, `secret_arn`, `secret_name`,
`identifier` — plus `amqp_endpoint`, `console_url`, `endpoints`, `broker_name`,
`broker_deployment_mode`, `is_cluster_mode`, `arn`, `ingress_ports`,
`admin_username`, the cross-stack context, and `helm_values`.

`amqp_endpoint` is the full `amqps://host:5671` URI as AmazonMQ reports it — use
it when a client wants one connection string instead of the split
scheme/host/port the chart uses.

`admin_username` is read from the stack variable rather than from the module
output. The module marks its copy `sensitive`, and referencing it would redact
the entire `helm_values` map and defeat the handoff.

`endpoints` is a list: a RabbitMQ cluster has no stable primary, so ordering is
not guaranteed.

## Shared mode

`mode = "shared"` creates nothing and plans to zero resources. Every lookup is
gated on `mode == "dedicated"`. The module resolves the broker with
`data "aws_mq_broker"` and the secret `shared-{env}-rabbitmq/password` with
`data "aws_secretsmanager_secret"`, so `endpoint`, `port`, `endpoints` and
`broker_deployment_mode` come from the resolved broker. `security_group_id`
comes back `null`.

### `shared_broker_name` — the one input that is not derivable

This is the only shared-mode variable of the four midaz datastores, and the
reason is the topology suffix. `data "aws_mq_broker"` matches the name
**exactly** and the AWS provider ships no list/filter data source for MQ, so the
`-single` / `-cluster` half of the shared broker's name has to be **declared,
not discovered**.

| | |
|---|---|
| Default (`""`) | derives `shared-{env}-rabbitmq-single` |
| Matches | `products/shared-resources/rabbitmq/envs/dev.tfvars-example` (`SINGLE_INSTANCE`) |
| stg / prd | `products/shared-resources/rabbitmq/envs/{stg,prd}.tfvars-example` ship `CLUSTER_MULTI_AZ` — set `shared_broker_name = "shared-{env}-rabbitmq-cluster"` |

Getting it wrong is loud, not silent: the plan fails naming the broker it
searched for. The secret is unaffected either way — it never carries the suffix,
so it resolves whichever topology the shared tier runs.
