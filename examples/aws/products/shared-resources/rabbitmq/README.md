# products/shared-resources/rabbitmq

The **shared message broker tier**: one Amazon MQ for RabbitMQ broker per
environment, owned by `product = "shared"`, consumed by any number of products.

| | |
| --- | --- |
| Module | [`_modules/rabbitmq-amazonmq`](../../../_modules/rabbitmq-amazonmq) |
| Creates | `shared-{env}-rabbitmq-single` **or** `shared-{env}-rabbitmq-cluster` |
| Secret | `shared-{env}-rabbitmq/password` — **no topology suffix** |
| A consumer resolves it with | `data "aws_mq_broker"` on the broker name, **suffix included** |
| State key | `aws/products/shared-resources/rabbitmq/terraform.tfstate` |
| dev cost | `mq.m7g.medium`, SINGLE_INSTANCE — **~USD 100/month** |

**Optional, and there is no cheap broker.** The RabbitMQ engine only accepts the
`mq.m5.*` and `mq.m7g.*` families; `mq.m7g.medium` is the smallest of them. The
burstable `mq.t2.*` / `mq.t3.*` types are **ActiveMQ-only** and AWS rejects them
for RabbitMQ in *every* deployment mode, `SINGLE_INSTANCE` included — the module
asserts the family at plan time rather than letting `CreateBroker` fail. dev's
only lever is the node count.

Applying this directory is what enables the tier; there is no `rabbitmq_enabled`
toggle. Read [`../README.md`](../README.md) for the trade-offs.

---

## Two "mode" axes, and only one of them is a variable here

| Axis | Where | Values |
| --- | --- | --- |
| Lerian sharing contract | the module's `mode`, **pinned to `dedicated`** | `dedicated` \| `shared` |
| AWS topology | `var.broker_deployment_mode` | `SINGLE_INSTANCE` \| `CLUSTER_MULTI_AZ` |

They are unrelated. This stack **creates**, so the sharing axis is pinned and is
not exposed as a variable — see the header of [`main.tf`](main.tf).

---

## THE COUPLING: this stack decides the name consumers must declare

`append_deployment_suffix` (default `true`) makes the broker name carry the
topology. **The secret and the security group never do — only the broker.**

`data "aws_mq_broker"` matches `broker_name` **exactly**, and the AWS provider
ships no list/filter data source for MQ. A shared consumer therefore cannot
*discover* the suffix; it has to *declare* it:

| This stack's `broker_deployment_mode` | Broker name | The consumer's `shared_broker_name` |
| --- | --- | --- |
| `SINGLE_INSTANCE` (dev example) | `shared-{env}-rabbitmq-single` | `""` — the derived default already matches |
| `CLUSTER_MULTI_AZ` (stg, prd examples) | `shared-{env}-rabbitmq-cluster` | `"shared-{env}-rabbitmq-cluster"` |

The two sides must agree, and the tfvars examples on both sides are written to
match: `products/midaz/rabbitmq/envs/{stg,prd}.tfvars-example` carry the
`-cluster` value because this tier's stg and prd examples ship
`CLUSTER_MULTI_AZ`.

**Changing `broker_deployment_mode` here is a breaking change for every shared
consumer.** It fails loudly, not silently: their plan aborts naming the broker
it searched for. Confirm the exact string with:

```bash
terraform output -raw broker_name
```

The suffix is also what makes a topology migration safe on a shared broker: the
two brokers **coexist** while consumers are repointed one at a time. See
[`_modules/rabbitmq-amazonmq/docs/UPGRADE-GUIDE.md`](../../../_modules/rabbitmq-amazonmq/docs/UPGRADE-GUIDE.md).

`product` is pinned to `"shared"` by validation for the same discovery-contract
reason.

---

## How a product consumes it

```hcl
# examples/aws/products/<product>/rabbitmq/envs/prd.tfvars
mode               = "shared"
shared_broker_name = "shared-prd-rabbitmq-cluster"   # match this tier's topology
```

The product's root creates nothing and reads
`shared-{env}-rabbitmq/password` — which carries no suffix, so it resolves
either way. Its `security_group_id` comes back `null`; opening the broker is
this stack's job.

The module creates **one** broker user. Per-product users and vhosts are created
on the broker itself, outside Terraform — and on a shared broker, a vhost per
product is the sane isolation boundary.

---

## Ingress

Scoped to **AMQPS (5671)** plus the **management console (443)**, which
`enable_console_ingress` opens by default: the midaz ledger's
`RABBITMQ_HEALTH_CHECK_URL` targets the management HTTP API on that port. The
pre-v2 module used `ip_protocol = "-1"` — every protocol, every port — and this
is the explicit, switchable replacement.

| Source | Variable | Default | Depends on |
| --- | --- | --- | --- |
| `Type=private` subnet CIDRs | `allow_private_subnet_cidr_ingress` | `true` | `infra-base/vpc` |
| EKS node security group | `eks_node_security_group_lookup_enabled` | `true` | `infra-base/eks` |
| Anything else | `allowed_security_group_ids`, `allowed_cidr_blocks` | `[]` | — |

---

## Init and apply

```bash
cd examples/aws/products/shared-resources/rabbitmq

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/shared-resources/rabbitmq/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

An AmazonMQ broker replacement is the slowest apply in this tier. Its own state
file is why it never blocks an RDS parameter change.

---

## Outputs

The seven uniform contract names, plus **`broker_name`** (the string a shared
consumer must declare), `broker_deployment_mode`, `is_cluster_mode`,
`amqp_endpoint`, `console_url`, `endpoints`, `arn`, `ingress_ports`,
`admin_username`, `helm_values`, and the four context outputs.

`endpoint` is the raw AWS broker host, with no scheme and no port. AmazonMQ
exposes **no plaintext AMQP listener**, so every client speaks AMQPS and the
broker certificate covers `*.mq.{region}.on.aws` only — a CNAME in front of it
would break hostname verification for everyone.

`helm_values` carries the **midaz chart** variable names, and the two port
variables are **named backwards in the chart** (`RABBITMQ_PORT_HOST` is the
AMQPS port, `RABBITMQ_PORT_AMQP` is the management port). That is a midaz-chart
convention, not a Lerian-wide one; see the header of [`outputs.tf`](outputs.tf).

---

## Validation

```bash
terraform fmt -check -recursive .
terraform init -backend=false -input=false
terraform validate
```
