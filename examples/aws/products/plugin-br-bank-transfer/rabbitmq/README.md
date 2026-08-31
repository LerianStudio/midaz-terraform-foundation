# products/plugin-br-bank-transfer/rabbitmq

**OPTIONAL.** Event bus for the TED lifecycle. Root stack over
[`_modules/rabbitmq-amazonmq`](../../../_modules/rabbitmq-amazonmq).

| | |
|---|---|
| Module | `../../../_modules/rabbitmq-amazonmq` |
| State key | `aws/products/plugin-br-bank-transfer/rabbitmq/terraform.tfstate` |
| Creates | `plugin-br-bank-transfer-{env}-rabbitmq-single` or `-cluster` (AmazonMQ broker) |
| Secret | `plugin-br-bank-transfer-{env}-rabbitmq/password` |
| Chart target | `bankTransfer.configmap` (`RABBITMQ_ENABLED`) — the URL is assembled elsewhere |

## Read this before applying

This is the only datastore of the four that the product ships **off**, and it is
off on two independent switches:

```yaml
rabbitmq:
  enabled: false                  # Chart.yaml dependency — no bundled broker
bankTransfer:
  configmap:
    RABBITMQ_ENABLED: "false"     # the application's own client switch
```

`templates/configmap.yaml` renders `RABBITMQ_URL` and `RABBITMQ_EXCHANGE` only
inside `{{- if eq (toString ... RABBITMQ_ENABLED) "true" }}`. With the defaults,
the plugin never opens an AMQP connection.

It is also the most expensive datastore of the four — roughly **USD 100/month**
floor, more than this product's PostgreSQL and Valkey combined. **Applying this
directory is a decision.** If the event bus is not used in an environment, do not
apply it; "not applied" is what "off" means in this repository. If it is used but
the cost is not acceptable, set `mode = "shared"` and consume
`products/shared-resources/rabbitmq`.

`helm_values` emits `RABBITMQ_ENABLED = "true"` for exactly that reason: applying
this directory *is* the decision that flips it.

## Run it

```bash
cd examples/aws/products/plugin-br-bank-transfer/rabbitmq

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/plugin-br-bank-transfer/rabbitmq/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

## `RABBITMQ_URL` is not emitted — and the usual workaround does not apply

`RABBITMQ_URL` is the only connection variable this chart has. There is no
`RABBITMQ_HOST`, no port key, no user key: scheme, credentials, host and port all
live in that one string. Terraform building it would write a cleartext password
into the state file and into `terraform output`.

The DocumentDB sibling of this product avoids exactly that problem with
`$(MONGO_PASSWORD)` expansion. It cannot be reused here:

| | delivery | `$(VAR)` expanded? |
|---|---|---|
| `MONGO_URI` | explicit `env:` entry with `value:`, from `_helpers.tpl` | **yes** |
| `RABBITMQ_URL` | ConfigMap key, delivered with `envFrom:` | **no** |

Kubernetes expands `$(VAR)` only in `env[].value`. Values sourced through
`envFrom` are passed through verbatim.

> **Chart finding.** The chart's own default is
> `amqp://bank_transfer:$(RABBITMQ_PASSWORD)@<release>-rabbitmq.<ns>...`, placed
> in the ConfigMap. That placeholder cannot be expanded from there, so the
> literal text `$(RABBITMQ_PASSWORD)` reaches the application — including on the
> bundled-subchart path. Reported in the product README; not something this stack
> can fix.

Assemble the URL in the secret store from `secret_name` plus the
`amqp_endpoint` output:

```
amqp_endpoint  ->  amqps://host:5671                       (credential-free)
RABBITMQ_URL   ->  amqps://USER:URLENCODED_PW@host:5671/
```

Two things to get right:

1. **The scheme must be `amqps`.** AmazonMQ for RabbitMQ publishes no plaintext
   AMQP listener at all, so the chart default's `amqp` cannot connect.
2. **Override the ConfigMap key, not just the Secret.**
   `templates/deployment.yaml` lists `secretRef` *before* `configMapRef` in
   `envFrom`, and later entries win — so a `RABBITMQ_URL` in the ConfigMap
   overrides one in the Secret. Set
   `bankTransfer.configmap.RABBITMQ_URL`, or use `bankTransfer.extraEnvVars`.

## `RABBITMQ_HOST` would be the raw broker host

If the chart ever grows a split host/port pair, the value is `endpoint` — the raw
AmazonMQ host. The broker certificate covers `*.mq.{region}.on.aws` and nothing
else, and the client always speaks AMQPS, so any alias in front of it fails
hostname verification. That is why this repository publishes no CNAMEs.

## Ingress

AMQPS (5671) plus, while `enable_console_ingress` is true, the management
console (443). Unlike the midaz and notifications charts, **nothing in this chart
calls the RabbitMQ management API** — there is no health-check URL pointed at it
— so turning the console off costs only the web UI. The exposure is bounded by
the ingress allow list either way.

## Topology on AmazonMQ is not seeded by the chart

The bundled-subchart path ships `files/rabbitmq/load_definition.json` and mounts
it with `management.load_definitions`, which creates the exchanges, queues and
bindings on first boot.

> **CONFIRMAR com o time:** AmazonMQ does not accept a definitions file. On the
> managed path the broker comes up empty, and whatever creates
> `bank_transfer.lifecycle` and its queues has to be an application bootstrap, a
> migration, or a manual step. Terraform creates no broker topology.

`RABBITMQ_EXCHANGE` is therefore not emitted either — it is application topology,
not infrastructure.

## Two things called "mode"

| Variable | Values | Meaning |
|---|---|---|
| `mode` | `dedicated` / `shared` | the **Lerian sharing contract** |
| `broker_deployment_mode` | `SINGLE_INSTANCE` / `CLUSTER_MULTI_AZ` | the **AWS topology** |

The broker *name* carries the topology suffix (`-single` / `-cluster`); the
secret and the security group never do. In shared mode, `shared_broker_name` is
the one input that is not derivable — `data "aws_mq_broker"` matches the name
exactly and the AWS provider ships no list/filter data source for MQ.

| | |
|---|---|
| Default (`""`) | derives `shared-{env}-rabbitmq-single` |
| stg / prd | the shared tier runs `CLUSTER_MULTI_AZ` — set `shared_broker_name = "shared-{env}-rabbitmq-cluster"` |

Getting it wrong is loud: the plan fails naming the broker it searched for.

## Instance types

Only `mq.m5.*` and `mq.m7g.*`. `mq.t2.*` and `mq.t3.*` are ActiveMQ-only and
AmazonMQ rejects them for RabbitMQ in *every* deployment mode; the module catches
it with a plan-time precondition. `mq.m7g.medium` is the smallest there is.

Dev's only saving is the node count (`SINGLE_INSTANCE`, one broker instead of
three), not a cheaper type.

## Outputs

The seven uniform contract names, plus `amqp_endpoint`, `console_url`,
`endpoints`, `broker_name`, `broker_deployment_mode`, `is_cluster_mode`, `arn`,
`ingress_ports`, `admin_username`, the four cross-stack context outputs, and
`helm_values`.

`amqp_endpoint` is the important one here: it is the credential-free half of the
`RABBITMQ_URL` the operator has to assemble.
