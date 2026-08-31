# products/br-sfn/rabbitmq

Message broker for the br-sfn SFN rails monorepo. Root stack over
[`_modules/rabbitmq-amazonmq`](../../../_modules/rabbitmq-amazonmq).

One root, one datastore, one state file. See [`../README.md`](../README.md) for
the product-level picture: deploy order, the shared-vs-dedicated model, and the
full Helm mapping.

| | |
|---|---|
| Module | `../../../_modules/rabbitmq-amazonmq` |
| State key | `aws/products/br-sfn/rabbitmq/terraform.tfstate` |
| Creates | `br-sfn-{env}-rabbitmq-single` or `-cluster` (AmazonMQ broker) |
| Secret | `br-sfn-{env}-rabbitmq/password` |
| Chart target | `correios.secrets.RABBITMQ_URL` — a SECRET, so `helm_values` is empty |
| Chart verified | br-sfn 1.1.0, appVersion `1.0.0-beta.1` |

The CRM deployment has no RabbitMQ variables.

## Run it

```bash
cd examples/aws/products/br-sfn/rabbitmq

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/br-sfn/rabbitmq/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

`../../../` is **three** levels up and lands on `examples/aws`, where both
`backend/` and `_modules/` live. Verified with `terraform init`.

Prerequisites: `infra-base/vpc`. `infra-base/eks` is optional at apply time —
see *Ingress* below.

An AmazonMQ broker replacement is the slowest apply of the four br-sfn datastores.
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
   Note the `lerian` prefix on both: they belong to `infra-base`, not to br-sfn.
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

Unlike midaz, **no br-sfn rail is known to use the management API**: the chart
defines no health-check URL variable, and its only AMQP key is a plain
`amqps://` connection URL. Console ingress is left on by default for operator
access and is bounded by the same allow list as AMQPS, but this is the one
product where turning it off is a defensible tightening rather than a broken
health check.

## `helm_values` is empty, and that is the finding

The br-sfn chart names **exactly one** AMQP variable, it belongs to **one** rail,
and it is a **secret**:

```yaml
correios:
  secrets:
    RABBITMQ_URL: ""      # values-template.yaml:80
```

A grep for `RABBITMQ`, `AMQP` or `MQ_` over the entire chart returns that line
plus three prose mentions of the external-infra contract. There is no
`RABBITMQ_HOST`, no `RABBITMQ_PORT`, no `RABBITMQ_URI` / `RABBITMQ_PROTOCOL`
scheme pair — **none of the shape `products/midaz/rabbitmq` emits**.

Terraform cannot fill a secret. `RABBITMQ_URL` is a complete connection URL with
the password inside it, and this repository never emits a password: it lives only
in Secrets Manager, read by External Secrets. Splitting the URL is not an option
either, because the chart offers no host/port keys to split it into.

So the operator assembles it, from four values this root does publish:

```yaml
correios:
  secrets:
    RABBITMQ_URL: "amqps://<admin_username>:<password>@<endpoint>:5671/"
```

| Piece | Where it comes from |
|---|---|
| `amqps` | mandatory — AmazonMQ publishes **no** plaintext AMQP listener |
| `<admin_username>` | the `admin_username` output |
| `<password>` | Secrets Manager, at `secret_name`. Never an output |
| `<endpoint>` | the `endpoint` output — the raw broker host |
| `5671` | the `port` output. AMQPS |
| trailing `/` | the default vhost AmazonMQ creates |

**`endpoint` is the raw broker host and there is no alternative.** The client
speaks AMQPS and the broker certificate covers `*.mq.{region}.on.aws` only, so an
alias in front of it fails TLS hostname verification. The cost is that replacing
the broker changes the URL and is therefore a values change — regenerated from
`terraform output`, so nothing is hardcoded, but the release has to be
re-rendered.

## The generated password is URL-safe — FIXED UPSTREAM

The password is interpolated into a URL, so this mattered.

The chart states the rule for Postgres in exactly these words — *"passwords must
be URL-safe (no `@ : / ? # %`)"* (`README.md:51`) — and it applies verbatim to
`RABBITMQ_URL`, which is a URL by construction.

`_modules/rabbitmq-amazonmq` **used to** generate the broker password with
`override_special = "!#$%^&*()-_+{}<>?"`, which includes `#`, `%` and `?`. `#`
truncates the URL at the fragment, `%` starts an invalid percent-escape and `?`
opens a query string — so the rail would either fail to connect or connect to
something unintended.

The module was fixed rather than worked around here: it now generates **32
characters** over alphanumerics plus `-_.~`, the RFC 3986 §2.3 *unreserved* set.
The AmazonMQ limits were checked at the same time — min 12 characters, `,:=`
forbidden, and a hard *"at least 4 unique characters"* API rule that the
module's `min_*` floors now satisfy deterministically. See
[`_modules/rabbitmq-amazonmq/README.md`](../../../_modules/rabbitmq-amazonmq/README.md).

Nothing to check before the first release, and nothing to percent-encode.

> **One-time migration cost.** Narrowing the set regenerates the password, so
> the first `apply` after this change **rotates** the broker admin credential.
> Workloads holding the old value fail authentication until External Secrets
> resyncs and the pods restart. Roll it dev → stg → prd, in a window.

> **CONFIRMAR no chart:** whether any rail other than `correios` speaks AMQP. The
> chart's infra contract lists RabbitMQ as external for the whole monorepo
> (`Chart.yaml:43-45`, `README.md:76`), but `correios` is the only component with
> an AMQP key. If `spb` / `spi` / `siloc` also use the broker, their variable
> names live in the br-sfn application repository — component configmaps and
> secrets are passed through verbatim, so the chart never has to name them.

Which **vhost** each rail should use is an application decision too. AmazonMQ
creates the default `/` and the URL above uses it.

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

The module creates **one** broker user (`mq_admin_user`), published as
`admin_username`. Any per-rail user is created on the broker itself, outside
Terraform.

The password is never an output. It lives in Secrets Manager at `secret_name`,
read by External Secrets — and here it has to be composed into `RABBITMQ_URL`
rather than handed over as a standalone value, which is what makes the URL-safety
section above load-bearing rather than pedantic.

`amqp_endpoint` is the closest thing to a ready-made value: the full
`amqps://host:5671` URI as AmazonMQ reports it, with **no credentials**. It is
the right base to interpolate the userinfo into.

## Outputs

Seven uniform contract names shared with every other Lerian datastore root —
`mode`, `endpoint`, `port`, `security_group_id`, `secret_arn`, `secret_name`,
`identifier` — plus `amqp_endpoint`, `console_url`, `endpoints`, `broker_name`,
`broker_deployment_mode`, `is_cluster_mode`, `arn`, `ingress_ports`,
`admin_username`, the cross-stack context, and `helm_values` — which is **empty here**, see
above.

`amqp_endpoint` is the full `amqps://host:5671` URI as AmazonMQ reports it, with
no credentials — the base to build `RABBITMQ_URL` from.

`admin_username` is read from the stack variable rather than from the module
output. The module marks its copy `sensitive`, and referencing it would redact
anything it is merged into.

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

This is the only shared-mode variable of the four br-sfn datastores, and the
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
