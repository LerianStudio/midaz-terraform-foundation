# products/reporter/rabbitmq

The AmazonMQ RabbitMQ broker of the **reporter** product. One root stack, one state file.

| | |
| --- | --- |
| Module | [`_modules/rabbitmq-amazonmq`](../../../_modules/rabbitmq-amazonmq) |
| Resource (dedicated) | `reporter-{env}-rabbitmq-single | -cluster` |
| Resource (shared) | `shared-{env}-rabbitmq-single | -cluster` |
| Secret | `reporter-{env}-rabbitmq/password` |
| State key | `aws/products/reporter/rabbitmq/terraform.tfstate` |
| Chart | `reporter-helm 3.2.0 (appVersion 2.3.0)` |

## Running it

```bash
cd examples/aws/products/reporter/rabbitmq

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/reporter/rabbitmq/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

`../../../` is **three** levels up, not four: this directory is
`examples/aws/products/reporter/rabbitmq`, so it lands on `examples/aws`, where
both `backend/` and `_modules/` live. `*.tfvars` is gitignored; `*.tfvars-example`
is not.

## Dedicated or shared

| `mode` | What happens | Resources |
| --- | --- | --- |
| `dedicated` (default) | Creates `reporter-{env}-rabbitmq-single | -cluster`, its security group and its secret. | all |
| `shared` | Creates nothing. Resolves `shared-{env}-rabbitmq-single | -cluster` and its secret by name, through a data source. | none |

In `shared` mode `security_group_id` comes back `null`: opening the shared
rabbitmq is the job of `products/shared-resources/rabbitmq`, not of this stack.

## Outputs

The seven uniform contract names — `mode`, `endpoint`, `port`,
`security_group_id`, `secret_arn`, `secret_name`, `identifier` — plus the
service-specific ones and `helm_values`. `endpoint` is the **raw AWS host** in
both modes: there is no private DNS zone in this repository, because every AWS
datastore presents a certificate for its own service domain and a CNAME in front
of it breaks TLS hostname verification.

## Helm handoff

```bash
terraform output -json helm_values | jq
```

| Terraform | Chart env var | Destination |
| --- | --- | --- |
| literal `"amqps"` | `RABBITMQ_URI` | `common.configmap` |
| `endpoint` | `RABBITMQ_HOST` | `common.configmap` |
| `port` (5671) | **`RABBITMQ_PORT_AMQP`** | `common.configmap` |
| `console_port` (443) | **`RABBITMQ_PORT_HOST`** | `common.configmap` |
| `"https://${endpoint}"` | `RABBITMQ_HEALTH_CHECK_URL` | `common.configmap` |
| `admin_username` | `RABBITMQ_DEFAULT_USER` | `secrets` |
| `secret_name` → External Secrets | `RABBITMQ_DEFAULT_PASS` | `secrets` |

Not emitted: `RABBITMQ_EXCHANGE`, `RABBITMQ_GENERATE_REPORT_QUEUE`,
`RABBITMQ_GENERATE_REPORT_KEY`, `RABBITMQ_NUMBERS_OF_WORKERS` (application
topology and tuning — AmazonMQ creates no exchanges or queues; the chart's
bootstrap Job does), `RABBITMQ_ERLANG_COOKIE` (only meaningful for the bundled
broker).

## Gotchas

- **The port variables are the opposite way round from midaz.** This is the
  single most dangerous thing to copy in this repository.

  | | AMQP(S) port | management HTTP port |
  | --- | --- | --- |
  | midaz | `RABBITMQ_PORT_HOST` | `RABBITMQ_PORT_AMQP` |
  | **reporter** | `RABBITMQ_PORT_AMQP` | `RABBITMQ_PORT_HOST` |

  Proven three times in the chart: `templates/NOTES.txt` labels them
  ("AMQP Port: `RABBITMQ_PORT_AMQP`", "Management Port: `RABBITMQ_PORT_HOST`");
  `templates/worker/keda-scaled-job.yaml` builds
  `{{ RABBITMQ_URI }}://{{ RABBITMQ_HOST }}:{{ RABBITMQ_PORT_AMQP }}`, an AMQP
  dial; and the manager init container waits on `$RABBITMQ_PORT_HOST` while the
  worker waits on `$RABBITMQ_PORT_AMQP`.
- **`RABBITMQ_URI` must be `amqps`.** AmazonMQ publishes no plaintext AMQP
  listener, so the chart default `amqp` cannot connect — and the KEDA trigger
  above would build an `amqp://` URL that never opens.
- **`RABBITMQ_PROTOCOL` does not exist in the application ConfigMap.** It appears
  only under `global.externalRabbitmqDefinitions.connection.protocol`, which
  configures the bootstrap Job. Set that to `https` with port `443` when pointing
  the Job at AmazonMQ.
- **KEDA needs credentials of its own.** `keda.triggerAuthentication` reads
  `RABBITMQ_DEFAULT_USER` / `RABBITMQ_DEFAULT_PASS` out of the manager Secret. If
  the ExternalSecret does not populate both, the ScaledJob authenticates as
  nobody and the worker never scales.
- The reporter chart ships `rabbitmq.enabled: true`. Set it to `false`; there is
  no `rabbitmq.external` key.

## Cost

`mq.m7g.medium`, SINGLE_INSTANCE, roughly **USD 100/month** in dev — the most
expensive datastore in the product, and there is no cheaper option. The RabbitMQ
engine only accepts the `mq.m5.*` and `mq.m7g.*` families; `mq.t3.micro`
(~USD 20/month) is **ActiveMQ-only** and AmazonMQ refuses it for RabbitMQ in every
deployment mode. The only dev lever is the node count, which is why dev stays
SINGLE_INSTANCE. *Estimates — price them against the AWS Pricing Calculator.*

## Validation

```bash
terraform fmt -check -recursive .
terraform init -backend=false -input=false
terraform validate
tflint --config=../../../../../.tflint.hcl
trivy config . --severity HIGH,CRITICAL --tf-exclude-downloaded-modules --quiet
```
