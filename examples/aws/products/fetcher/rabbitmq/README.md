# products/fetcher/rabbitmq

The AmazonMQ RabbitMQ broker of the **fetcher** product. One root stack, one state file.

| | |
| --- | --- |
| Module | [`_modules/rabbitmq-amazonmq`](../../../_modules/rabbitmq-amazonmq) |
| Resource (dedicated) | `fetcher-{env}-rabbitmq-single | -cluster` |
| Resource (shared) | `shared-{env}-rabbitmq-single | -cluster` |
| Secret | `fetcher-{env}-rabbitmq/password` |
| State key | `aws/products/fetcher/rabbitmq/terraform.tfstate` |
| Chart | `fetcher-helm 3.1.0 (appVersion 3.0.2)` |

## Running it

```bash
cd examples/aws/products/fetcher/rabbitmq

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/fetcher/rabbitmq/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

`../../../` is **three** levels up, not four: this directory is
`examples/aws/products/fetcher/rabbitmq`, so it lands on `examples/aws`, where
both `backend/` and `_modules/` live. `*.tfvars` is gitignored; `*.tfvars-example`
is not.

## Dedicated or shared

| `mode` | What happens | Resources |
| --- | --- | --- |
| `dedicated` (default) | Creates `fetcher-{env}-rabbitmq-single | -cluster`, its security group and its secret. | all |
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
| `admin_username` | `RABBITMQ_DEFAULT_USER` | **`secrets`** |
| `secret_name` → External Secrets | `RABBITMQ_DEFAULT_PASS` | `secrets` |

Not emitted: `RABBITMQ_FETCHER_WORK_QUEUE`, `RABBITMQ_JOB_EVENTS_EXCHANGE`,
`RABBITMQ_NUMBERS_OF_WORKERS` (application topology, and they live in
`worker.configmap`), `RABBITMQ_ERLANG_COOKIE`.

## Gotchas

- **The port variables are the opposite way round from midaz**, exactly as in
  reporter.

  | | AMQP(S) port | management HTTP port |
  | --- | --- | --- |
  | midaz | `RABBITMQ_PORT_HOST` | `RABBITMQ_PORT_AMQP` |
  | **fetcher** | `RABBITMQ_PORT_AMQP` | `RABBITMQ_PORT_HOST` |

  `values.yaml` ships `RABBITMQ_PORT_AMQP: "5672"`, `RABBITMQ_PORT_HOST: "15672"`
  and `RABBITMQ_HEALTH_CHECK_URL: "http://rabbitmq:15672"` — the health check URL
  carrying the same number as `PORT_HOST` is what pins the mapping down.
- **`RABBITMQ_URI` must be `amqps`.** AmazonMQ publishes no plaintext listener.
- **`RABBITMQ_DEFAULT_USER` belongs in `secrets:`**, not in the ConfigMap.
- `templates/bootstrap-rabbitmq.yaml` declares the work queue and the job-events
  exchange over the management API, which is why `enable_console_ingress` stays
  true.
- The fetcher chart already ships `rabbitmq.enabled: false`.

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
