# products/plugin-bc-correios/rabbitmq

The AmazonMQ RabbitMQ broker of the **plugin-bc-correios** product. One root stack, one state file.

| | |
| --- | --- |
| Module | [`_modules/rabbitmq-amazonmq`](../../../_modules/rabbitmq-amazonmq) |
| Resource (dedicated) | `plugin-bc-correios-{env}-rabbitmq-single | -cluster` |
| Resource (shared) | `shared-{env}-rabbitmq-single | -cluster` |
| Secret | `plugin-bc-correios-{env}-rabbitmq/password` |
| State key | `aws/products/plugin-bc-correios/rabbitmq/terraform.tfstate` |
| Chart | `plugin-bc-correios-helm 2.2.0 (appVersion 1.2.0)` |

## Running it

```bash
cd examples/aws/products/plugin-bc-correios/rabbitmq

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/plugin-bc-correios/rabbitmq/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

`../../../` is **three** levels up, not four: this directory is
`examples/aws/products/plugin-bc-correios/rabbitmq`, so it lands on `examples/aws`, where
both `backend/` and `_modules/` live. `*.tfvars` is gitignored; `*.tfvars-example`
is not.

## Dedicated or shared

| `mode` | What happens | Resources |
| --- | --- | --- |
| `dedicated` (default) | Creates `plugin-bc-correios-{env}-rabbitmq-single | -cluster`, its security group and its secret. | all |
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
| `endpoint` | `RABBITMQ_HOST` | `bc-correios.configmap` |
| `admin_username` | `RABBITMQ_USER` | `bc-correios.configmap` |
| assembled by External Secrets | `RABBITMQ_URL` | `bc-correios.secrets` |
| `secret_name` → External Secrets | `RABBITMQ_PASS` | `bc-correios.secrets` |

`RABBITMQ_URL` is the connection the application actually uses, and it embeds the
password, so Terraform must not emit it. Assemble it in the ExternalSecret:

```
amqps://<RABBITMQ_USER>:<password>@<endpoint>:5671/
```

The `amqp_endpoint` output of this stack is the same URI without credentials —
the safe half to copy. Note `amqps`, not `amqp`.

## Gotchas

- **BLOCKER: the init container hardcodes port 5672 and AmazonMQ does not listen
  on it.** `templates/deployment.yaml`:

  ```sh
  # Wait for RabbitMQ (AMQP port)
  wait_for_service "$RABBITMQ_HOST" "5672"
  ```

  The port is a literal, not a value. AmazonMQ for RabbitMQ publishes only AMQPS
  on 5671, so this TCP check can never succeed against a managed broker: the init
  container retries for its full 300-second timeout, exits 1, and the pod never
  reaches the application container. **No Terraform value fixes this — it needs a
  chart change.** Until then, either keep the bundled in-cluster broker for this
  product or patch the init container. This stack is still correct and worth
  applying; do not schedule the Helm cutover.
- **There is no port variable at all** in this chart's RabbitMQ surface.
  `RABBITMQ_HOST` exists only for the init container's TCP check; the application
  connects through `RABBITMQ_URL`.
- **The bundled subchart image is RabbitMQ 4.0.5** (the other two products ship
  3.13.6). That is the in-cluster broker's version and has no bearing on
  AmazonMQ, which does not offer 4.x — `engine_version = "3.13"` here is the
  AmazonMQ-supported version. Do not "align" the two.
- `global.externalRabbitmqDefinitions` bootstraps the user, vhost and permissions
  over the management API. Set its `connection.protocol` to `https` and
  `connection.port` to `443` when pointing it at AmazonMQ.
- Set `rabbitmq.enabled: false` **and** `rabbitmq.external: true`.

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
