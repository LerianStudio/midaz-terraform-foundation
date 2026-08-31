# products/notifications/rabbitmq

Message broker for the notifications outbox and the three delivery queues
(email, SMS, webhook). Root stack over
[`_modules/rabbitmq-amazonmq`](../../../_modules/rabbitmq-amazonmq).

One root, one datastore, one state file. See [`../README.md`](../README.md) for
the product-level picture.

| | |
|---|---|
| Module | `../../../_modules/rabbitmq-amazonmq` |
| State key | `aws/products/notifications/rabbitmq/terraform.tfstate` |
| Creates | `notifications-{env}-rabbitmq-single` or `-cluster` (AmazonMQ broker) |
| Secret | `notifications-{env}-rabbitmq/password` |
| Chart target | `.Values.config` (`RABBITMQ_HOST`, the two port keys) and `.Values.secrets` (`RABBITMQ_DEFAULT_USER`) |

## Run it

```bash
cd examples/aws/products/notifications/rabbitmq

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/notifications/rabbitmq/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

An AmazonMQ broker replacement is the slowest apply of the three notifications
datastores. Per-service state means it never blocks an RDS parameter change.

## READ THIS BEFORE COPYING ANYTHING FROM `products/midaz/rabbitmq`

The two port variables have the **same names** and the **opposite meanings**.

| | notifications chart | midaz chart |
|---|---|---|
| `RABBITMQ_PORT_AMQP` | the AMQP(S) port | the management HTTP port |
| `RABBITMQ_PORT_HOST` | the management HTTP port | the AMQP(S) port |

Evidence for this chart, `values.yaml` `config` block:

```yaml
RABBITMQ_PORT_AMQP: "5672"    # AMQP upstream
RABBITMQ_PORT_HOST: "15672"   # management API upstream
```

Each name means what it says. `values-template.yaml` reinforces it by listing
`RABBITMQ_PORT_AMQP` as the one port an operator normally overrides. midaz's
inversion is documented in
[`products/midaz/rabbitmq/README.md`](../../midaz/rabbitmq/README.md) and is a
midaz-chart convention, not a Lerian-wide one.

`helm_values` therefore emits:

| Terraform | Chart key | Value |
|---|---|---|
| `port` | `RABBITMQ_PORT_AMQP` | `5671` |
| `console_port` | `RABBITMQ_PORT_HOST` | `443` |

The AmazonMQ numbers, not the chart defaults: AmazonMQ serves AMQPS on 5671
(there is **no** plaintext AMQP listener) and the management API over HTTPS on
443.

## Two things called "mode"

| Variable | Values | Meaning |
|---|---|---|
| `mode` | `dedicated` / `shared` | the **Lerian sharing contract** — create the broker, or resolve one that exists |
| `broker_deployment_mode` | `SINGLE_INSTANCE` / `CLUSTER_MULTI_AZ` | the **AWS topology** |

The broker *name* carries the topology suffix (`-single` / `-cluster`); the
secret and the security group never do.

## `RABBITMQ_HOST` is the raw broker host

Always, in both modes, with no switch to flip. AmazonMQ for RabbitMQ publishes
no plaintext AMQP listener, the client always speaks AMQPS, and the broker
certificate covers `*.mq.{region}.on.aws` and nothing else — so any alias in
front of it fails hostname verification. That is why this repository publishes
no CNAMEs.

The cost to plan around: replacing the broker changes `RABBITMQ_HOST`, so a
replacement is a Helm values change. `terraform output` regenerates it on every
deploy, so nothing is hardcoded, but the release has to be re-rendered.

## What is NOT emitted, and why

**`RABBITMQ_URL`** — the chart's full AMQP URL, in `.Values.secrets`, embedding
the credentials. Terraform must not build it: the value would land in the state
file and in `terraform output` in cleartext. Assemble it in the secret store
from `secret_name` plus the `amqp_endpoint` output, which is the same URI
without credentials:

```
amqp_endpoint  ->  amqps://host:5671
RABBITMQ_URL   ->  amqps://USER:URLENCODED_PW@host:5671/
```

**`RABBITMQ_HEALTH_CHECK_URL`** — an open question, not a policy:

> **CONFIRMAR no chart.** The chart keeps it in `.Values.secrets`, which implies
> it is expected to carry credentials for the management API, but nothing in the
> chart documents its path or whether the credentials are inline. The host half
> is unambiguous — `https://<endpoint>`, port omitted because 443 is implicit —
> the rest is not. It stays unemitted until the notifications team confirms the
> shape. Related knobs that are also chart decisions:
> `RABBITMQ_ALLOW_INSECURE_HEALTH_CHECK` and
> `RABBITMQ_REQUIRE_HEALTH_ALLOWED_HOSTS`.

**`RABBITMQ_VHOST`** — AmazonMQ creates the default `/` vhost and the chart
default is already `/`. Nothing for Terraform to correct.

**`RABBITMQ_EXCHANGE`** — application topology (`events`), not infrastructure.
Terraform creates no exchanges; the broker is empty on first boot. The same goes
for every `RABBITMQ_PUBLISHER_*` and `OUTBOX_*` knob.

**`RABBITMQ_DEFAULT_PASS`** — read from `secret_name` by External Secrets.

`RABBITMQ_DEFAULT_USER` **is** emitted, but into `helm_secret_values`: it is a
username, not a credential, and the chart simply reads it from the Secret next
to the password.

## Ingress

AMQPS (5671) plus, while `enable_console_ingress` is true, the management
console (443). Turning the console off does not just hide the web UI — the
chart's `RABBITMQ_HEALTH_CHECK_URL` targets the management HTTP API on that
port, so it breaks the broker health check too. The exposure is bounded by the
ingress allow list, not by the port list; leave it on.

## Instance types

The RabbitMQ engine accepts **only** the `mq.m5.*` and `mq.m7g.*` families.
`mq.t2.*` and `mq.t3.*` are ActiveMQ-only and AmazonMQ rejects them for RabbitMQ
in *every* deployment mode, `SINGLE_INSTANCE` included. The module catches this
with a plan-time precondition.

`mq.m7g.medium` is the smallest RabbitMQ type there is — roughly USD 100/month,
more than the notifications database and cache put together. Dev's only saving
is the node count (`SINGLE_INSTANCE`, one broker instead of three), not a
cheaper type. If that is unacceptable for an ephemeral environment, set
`mode = "shared"` and consume `products/shared-resources/rabbitmq`.

## Shared mode

`mode = "shared"` creates nothing and plans to zero resources.
`shared_broker_name` is the one input that is not derivable: `data
"aws_mq_broker"` matches the name exactly, the AWS provider ships no
list/filter data source for MQ, and the broker name carries the topology suffix.

| | |
|---|---|
| Default (`""`) | derives `shared-{env}-rabbitmq-single` |
| Matches | `products/shared-resources/rabbitmq/envs/dev.tfvars-example` (`SINGLE_INSTANCE`) |
| stg / prd | those tfvars ship `CLUSTER_MULTI_AZ` — set `shared_broker_name = "shared-{env}-rabbitmq-cluster"` |

Getting it wrong is loud, not silent: the plan fails naming the broker it
searched for. The secret is unaffected — it never carries the suffix.

## Outputs

The seven uniform contract names, plus `amqp_endpoint`, `console_url`,
`endpoints`, `broker_name`, `broker_deployment_mode`, `is_cluster_mode`, `arn`,
`ingress_ports`, `admin_username`, the four cross-stack context outputs,
`helm_values` and `helm_secret_values`.
