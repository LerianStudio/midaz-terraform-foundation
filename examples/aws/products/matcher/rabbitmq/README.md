# products/matcher/rabbitmq

Message broker for the Matcher reconciliation service. Root stack over
[`_modules/rabbitmq-amazonmq`](../../../_modules/rabbitmq-amazonmq).

> **Composition inferred, and this is the least certain root in the repository.**
> Read the section below before applying it. `helm_values` is empty on purpose.

| | |
|---|---|
| Module | `../../../_modules/rabbitmq-amazonmq` |
| State key | `aws/products/matcher/rabbitmq/terraform.tfstate` |
| Creates | `matcher-{env}-rabbitmq-single` or `-cluster` (AmazonMQ broker) |
| Secret | `matcher-{env}-rabbitmq/password` |
| Chart target | **unknown** — no readable chart |

## Confirm before applying

The evidence for this datastore is one file:
`charts/matcher/charts/rabbitmq-2.1.11.tgz`, the groundhog2k RabbitMQ chart at
the same version midaz and plugin-br-bank-transfer pin.

That proves the Matcher chart **declares** a `rabbitmq` dependency. It does not
prove the broker is used:

> `plugin-br-bank-transfer` vendors the **identical** tarball and ships the
> subchart `enabled: false`, with the application's own `RABBITMQ_ENABLED`
> defaulting to `"false"` on top. A vendored tarball is evidence of a
> declaration, not of a runtime requirement.

And the cost is not marginal: roughly **USD 100/month** for the smallest AmazonMQ
RabbitMQ broker, about four times this product's PostgreSQL and Valkey combined.

> **CONFIRMAR com o time Matcher:** is the broker used at runtime, or is it a
> declared-but-disabled dependency? If disabled, do not apply this directory —
> "not applied" is what "off" means in this repository. If it is used but the
> cost is not acceptable in this environment, set `mode = "shared"` and consume
> `products/shared-resources/rabbitmq`.

## Run it

```bash
cd examples/aws/products/matcher/rabbitmq

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/matcher/rabbitmq/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

## Wiring the release, for now

```bash
terraform output endpoint        # the raw broker host, no scheme, no port
terraform output port            # 5671 (AMQPS)
terraform output amqp_endpoint   # amqps://host:5671 — credential-free
terraform output console_url     # the management console
terraform output admin_username
terraform output secret_name     # -> External Secrets -> the password
```

**The scheme must be `amqps`.** AmazonMQ for RabbitMQ publishes no plaintext AMQP
listener at all, so whatever variable the Matcher chart uses, `amqp://` cannot
connect.

**`endpoint` is the raw broker host, always.** The broker certificate covers
`*.mq.{region}.on.aws` and nothing else, and the client always speaks AMQPS, so
any alias in front of it fails hostname verification. That is why this repository
publishes no CNAMEs.

For orientation only, not a recommendation to hardcode:

| Chart | Shape |
|---|---|
| midaz | `RABBITMQ_HOST` + `RABBITMQ_PORT_HOST` (AMQP) + `RABBITMQ_PORT_AMQP` (management) |
| notifications | `RABBITMQ_HOST` + `RABBITMQ_PORT_AMQP` (AMQP) + `RABBITMQ_PORT_HOST` (management) — **the same two names, swapped** |
| plugin-br-bank-transfer | a single `RABBITMQ_URL` with credentials inline |

Three charts, three contracts, and two of them reuse the same identifiers with
opposite meanings. This is exactly why nothing is guessed here.

## Two things called "mode"

| Variable | Values | Meaning |
|---|---|---|
| `mode` | `dedicated` / `shared` | the **Lerian sharing contract** |
| `broker_deployment_mode` | `SINGLE_INSTANCE` / `CLUSTER_MULTI_AZ` | the **AWS topology** |

The broker *name* carries the topology suffix (`-single` / `-cluster`); the
secret and the security group never do.

In shared mode, `shared_broker_name` is the one input that is not derivable —
`data "aws_mq_broker"` matches the name exactly and the AWS provider ships no
list/filter data source for MQ:

| | |
|---|---|
| Default (`""`) | derives `shared-{env}-rabbitmq-single` |
| stg / prd | the shared tier runs `CLUSTER_MULTI_AZ` — set `shared_broker_name = "shared-{env}-rabbitmq-cluster"` |

Getting it wrong is loud, not silent: the plan fails naming the broker it
searched for.

## Ingress

AMQPS (5671) plus, while `enable_console_ingress` is true, the management console
(443). It is left on because a broker health check against the management API is
a common Lerian pattern (midaz does it) and there is no chart here to rule it
out. The exposure is bounded by the ingress allow list, not by the port list.

## Instance types

Only `mq.m5.*` and `mq.m7g.*` are accepted by the RabbitMQ engine. `mq.t2.*` and
`mq.t3.*` are ActiveMQ-only and AmazonMQ rejects them for RabbitMQ in *every*
deployment mode, `SINGLE_INSTANCE` included; the module catches it with a
plan-time precondition.

`mq.m7g.medium` is the smallest there is. Dev's only saving is the node count
(`SINGLE_INSTANCE`, one broker instead of three), not a cheaper type.

## Broker topology is not created by Terraform

The broker comes up empty: no exchanges, no queues, no bindings, and one user
(`mq_admin_user`). Whatever the Matcher application expects has to be created by
the application, a migration, or an operator — and note that AmazonMQ does not
accept a RabbitMQ definitions file, so the `load_definitions` pattern the
bundled-subchart path uses elsewhere in this repository does not transfer.

## Outputs

The seven uniform contract names, plus `amqp_endpoint`, `console_url`,
`endpoints`, `broker_name`, `broker_deployment_mode`, `is_cluster_mode`, `arn`,
`ingress_ports`, `admin_username`, the four cross-stack context outputs, and
`helm_values` — which is `{}` and explains itself in the file.
