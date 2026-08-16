Message broker for the plugin-br-pix-switch DICT verification sync worker —
**one** of the chart's ten components uses it. Root stack over
[`_modules/rabbitmq-amazonmq`](../../../_modules/rabbitmq-amazonmq).

One root, one datastore, one state file. See [`../README.md`](../README.md) for
the product-level picture: deploy order, the shared-vs-dedicated model, and the
full Helm mapping.

| | |
|---|---|
| Module | `../../../_modules/rabbitmq-amazonmq` |
| State key | `aws/products/plugin-br-pix-switch/rabbitmq/terraform.tfstate` |
| Creates | `plugin-br-pix-switch-{env}-rabbitmq-single` or `-cluster` (AmazonMQ broker) |
| Secret | `plugin-br-pix-switch-{env}-rabbitmq/password` |
| Chart target | `dictHubVsync.secrets.RABBITMQ_URI` (a **secret**) |
| Chart verified | plugin-br-pix-switch 2.0.0-beta.1+ |

The CRM deployment has no RabbitMQ variables.

## Run it

```bash
cd examples/aws/products/plugin-br-pix-switch/rabbitmq

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/plugin-br-pix-switch/rabbitmq/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

`../../../` is **three** levels up and lands on `examples/aws`, where both
`backend/` and `_modules/` live. Verified with `terraform init`.

Prerequisites: `infra-base/vpc`. `infra-base/eks` is optional at apply time —
see *Ingress* below.

An AmazonMQ broker replacement is the slowest apply of the four plugin-br-pix-switch datastores.
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
   Note the `lerian` prefix on both: they belong to `infra-base`, not to plugin-br-pix-switch.
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
`enable_console_ingress` is true, the management console and management HTTP API
(443).

Unlike midaz, **no plugin-br-pix-switch component uses the management API**: the
chart names no health-check URL variable, and its only AMQP key is a plain
`amqps://` connection URI. Console ingress is left on by default for operator
access and is bounded by the same allow list as AMQPS, but this is a product
where turning it off is a defensible tightening rather than a broken health
check.

## The chart consumes a URI — so `helm_values` is empty

The chart reads the broker through **one key**, on **one component**, and it is a
full connection URL in a Secret:

```yaml
dictHubVsync:
  secrets:
    # TLS-only: amqps:// on 5671. lib-commons v5.7.0 validates the broker cert
    # against the system trust store (a private CA needs an app-code change).
    RABBITMQ_URI: "amqps://pixswitch:<password>@rabbitmq-host:5671/"
```
(`values-template.yaml:102-104` — the comment is the chart's own)

There is **no** `RABBITMQ_HOST`, no `RABBITMQ_PORT`, no `RABBITMQ_URI` /
`RABBITMQ_PROTOCOL` scheme pair, and no management-port variable — none of the
shape `products/midaz/rabbitmq` emits. `dictHubVsync.secrets` is emitted verbatim
into a Secret and that is the whole contract.

Terraform cannot fill a secret, and there is no leftover non-secret surface (no
bootstrap Job for the broker). So `helm_values` is **empty** and the shape is
published as `rabbitmq_uri_template`:

```bash
terraform output -raw rabbitmq_uri_template
# amqps://<mq_admin_user>:<password>@<endpoint>:5671/
```

## This is the best-aligned pairing in the product

Everything the chart asks for is what AmazonMQ already does:

| Chart | AmazonMQ |
|---|---|
| `amqps://` on `5671`, TLS-only | the **only** listener — there is no plaintext AMQP |
| *"lib-commons validates the broker cert against the system trust store"* | the broker presents a publicly-trusted cert for `*.mq.{region}.on.aws` |
| the in-cluster subchart is disabled because it *"would present a self-signed cert that lib-commons rejects"* (`values.yaml:1465-1468`) | exactly the problem a managed broker removes |
| *"For external RabbitMQ / AmazonMQ set `enabled: false`"* (`values.yaml:1493-1494`) | already the chart default |

**That trust-store requirement is also why `endpoint` must be used raw.** An
alias in front of the broker fails the same hostname verification the chart says
lib-commons performs — there is no CNAME anywhere in this repository for exactly
that reason.

The cost is that replacing the broker changes the host and is therefore a values
change. Regenerated from `terraform output`, so nothing is hardcoded, but the
release has to be re-rendered.

## The generated password is URL-safe — FIXED UPSTREAM

The password is interpolated into a URL, so this mattered.

`_modules/rabbitmq-amazonmq` **used to** generate it with
`override_special = "!#$%^&*()-_+{}<>?"`, which includes `#`, `%` and `?`. `#`
truncates the URI at the fragment, `%` starts an invalid percent-escape and `?`
opens a query string — so the worker would either fail to connect or connect
somewhere unintended.

It now draws **32 characters** from alphanumerics plus `-_.~`, the RFC 3986 §2.3
*unreserved* set, so no percent-encoding is needed in any position of the URI.
The AmazonMQ limits were verified at the same time — min 12, `,:=` forbidden,
and a hard *"at least 4 unique characters"* API rule the module now satisfies
deterministically. This applies to every datastore in this product; see
[`../README.md`](../README.md).

> **One-time migration cost.** The narrowing regenerates the password, so the
> first `apply` after this change **rotates** the broker admin credential. Roll
> it dev → stg → prd, in a window.

## The vhost, and the username

The trailing `/` in the URI is the **default vhost** AmazonMQ creates. Which
vhost the worker should use is an application decision, not an infrastructure
one.

The chart's example username is `pixswitch`; that is a chart-side placeholder,
not a requirement. `rabbitmq_uri_template` carries whatever `mq_admin_user` is.
The module creates **one** broker user — a dedicated worker user is created on
the broker itself, outside Terraform.

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

## Outputs

Seven uniform contract names shared with every other Lerian datastore root —
`mode`, `endpoint`, `port`, `security_group_id`, `secret_arn`, `secret_name`,
`identifier` — plus `amqp_endpoint`, `console_url`, `endpoints`, `broker_name`,
`broker_deployment_mode`, `is_cluster_mode`, `arn`, `ingress_ports`,
`admin_username`, the cross-stack context, `helm_values` (empty) and
`rabbitmq_uri_template`.

`amqp_endpoint` is the full `amqps://host:5671` URI as AmazonMQ reports it, with
**no credentials** — the same value `rabbitmq_uri_template` builds on.

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

This is the only shared-mode variable of the four plugin-br-pix-switch datastores, and the
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
