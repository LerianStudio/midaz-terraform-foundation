# products/plugin-fees/msk

Kafka for plugin-fees. Root stack over
[`_modules/streaming-msk`](../../../_modules/streaming-msk).

**This directory is OPT-IN, and the tfvars ship `mode = "shared"`.** Read the
next section before applying anything. See [`../README.md`](../README.md) for the
product-level picture.

| | |
|---|---|
| Module | `../../../_modules/streaming-msk` |
| State key | `aws/products/plugin-fees/msk/terraform.tfstate` |
| Creates (dedicated) | `plugin-fees-{env}-msk` (MSK cluster) |
| Resolves (shared) | `shared-{env}-msk`, owned by `products/shared-resources/msk` |
| Secret | `AmazonMSK_plugin-fees-{env}-msk` / `AmazonMSK_shared-{env}-msk` |
| Chart target | `.Values.fees.configmap` — **except `STREAMING_BROKERS`**, see below |

## Two reasons not to apply this with `mode = "dedicated"`

**1. Streaming is off by default in the chart.** `STREAMING_ENABLED` renders
`"false"` (`templates/fees/configmap.yaml:120`) and the key is not even present
in `values.yaml`.

**2. MSK has no cheap corner.** `kafka.t3.small` is the smallest broker AWS
offers, the minimum is two brokers, and `number_of_broker_nodes` must be a
**multiple of the number of client subnets**. `infra-base/vpc` tags three subnets
`Type=database`, so the valid values are 3, 6, 9 — three brokers is the real
floor, roughly **USD 105/month**. A 2-broker cluster needs `subnet_ids` narrowed
to exactly two ids, which cannot go in a `tfvars-example` because the ids are
generated.

All three `envs/*.tfvars-example` therefore set `mode = "shared"`, overriding the
variable default. The default stays `"dedicated"` only so this root behaves like
every other product root.

`envs/prd.tfvars-example` lists the three conditions that would justify
switching.

## Run it

```bash
cd examples/aws/products/plugin-fees/msk

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/plugin-fees/msk/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

`../../../` is **three** levels up and lands on `examples/aws`. Verified with
`terraform init`.

Prerequisites: `infra-base/vpc`, and — because the tfvars ship `shared` —
`products/shared-resources/msk` **applied first**. `data "aws_msk_cluster"` is
singular and fails the plan when it does not match, naming the cluster it looked
for. That is the desired behaviour: an unresolvable shared cluster must stop the
apply rather than emit a null broker list into the Helm values.

## `mode` means "create or resolve", not "is it shared"

| `mode` | What the stack does | `security_group_id` |
|---|---|---|
| `shared` (what the tfvars set) | Creates nothing. Resolves `shared-{env}-msk` and `AmazonMSK_shared-{env}-msk`. Plans to zero resources. | `null` |
| `dedicated` | Creates `plugin-fees-{env}-msk`, its security group, its CMKs and its Secrets Manager entry. | the created group |

In shared mode this product **cannot authorise itself** on the cluster — it
creates no security group. Opening the shared cluster is
`products/shared-resources/msk`' job.

`scram_username` is *declared*, not discovered: the module reads the shared
secret by name, but the username comes from this stack. A mismatch with the
shared tier produces an authentication failure at runtime rather than a plan
error. Both sides default to `lerian`.

## Ingress — ignored in shared mode

Performed by
[`_modules/product-network`](../../../_modules/product-network) with
`enabled = var.mode == "dedicated"`.

> `var.subnet_tag_type` (`"database"`) selects the **client subnets the brokers
> are placed in** and goes to `streaming-msk` only, alongside `var.subnet_ids`.
> `product-network` keeps its own default (`"private"`), the subnets whose CIDRs
> become **ingress**.

`allow_private_subnet_cidr_ingress` matters more on MSK than anywhere else: the
module used to ship no VPC-CIDR fallback at all, so empty allow lists produced a
cluster with zero ingress that looked healthy and accepted no connections. It now
carries `check "ingress_is_reachable"`.

## Helm handoff — and the gap in it

Verified against **plugin-fees-helm 7.3.0**,
`templates/fees/configmap.yaml:119-126` and `templates/fees/secrets.yaml:35-39`.
Eight `STREAMING_*` ConfigMap keys and two Secret keys; that is the whole set.

Emitted into `.Values.fees.configmap`:

| Terraform | Chart env var |
|---|---|
| literal `"true"` | `STREAMING_ENABLED` |
| derived from `encryption_in_transit_client_broker` | `STREAMING_TLS_ENABLED` |
| `scram_username` | `STREAMING_SASL_USERNAME` |
| literal `"false"` | `STREAMING_SASL_ALLOW_PLAINTEXT` |
| `secret_name` → External Secrets | `STREAMING_SASL_PASSWORD` |

### `STREAMING_BROKERS` does not exist in this chart

Checked independently, not assumed from the identical midaz finding. Grep for
`STREAMING` returns thirteen hits; grep for `broker` and for `kafka` returns
**zero**. The chart can enable streaming and configure its TLS and SASL, and has
nowhere to put a broker address.

`helm_values` emits `STREAMING_BROKERS` anyway — under the name the
`streaming-msk` module README already uses — but it must be injected through
**`fees.extraEnvVars`** until the chart grows the variable. When it does, the
wiring becomes a rename rather than a rediscovery.

### `STREAMING_SASL_MECHANISM` is omitted — one open `CONFIRMAR`

MSK implements **SCRAM-SHA-512 and nothing else**; that half is settled. The
spelling the Lerian streaming client accepts is not verifiable from the chart:
`configmap.yaml:123` renders the key with an empty default, and no template,
values file or `values.schema.json` enumerates accepted strings.

`SCRAM-SHA-512` vs `scram-sha-512` vs `SCRAM_SHA_512` is a coin flip whose losing
side is an authentication failure nobody would trace back to a Terraform output.
So `var.streaming_sasl_mechanism` defaults to `""`, which **omits the key**.

Confirm against `lib-streaming`, then set the variable once.

### A chart bug that affects TLS wiring

`templates/fees/deployment.yaml:51-55` lists `envFrom` as `secretRef` first and
`configMapRef` second. Kubernetes lets the later source win on duplicate keys,
and `STREAMING_TLS_CA_CERT` is defined in **both** — the ConfigMap always renders
it (default: five literal spaces), so it overwrites the Secret copy.

Harmless as shipped, because the public Amazon trust store already covers MSK
broker certificates and `STREAMING_TLS_CA_CERT` is not emitted here. But if a
bundle is ever needed it has to go in the ConfigMap copy or through
`extraEnvVars`. Reported, not worked around — Terraform cannot fix `envFrom`
ordering.

## Outputs

Seven uniform contract names — `mode`, `endpoint`, `port`, `security_group_id`,
`secret_arn`, `secret_name`, `identifier` — plus `bootstrap_brokers*`,
`zookeeper_connect_string`, `cluster_arn`, `cluster_uuid`, `configuration_arn`,
`kms_key_arn`, `scram_kms_key_arn`, `log_group_arn`, the cross-stack context
(`vpc_name`, `eks_cluster_name`, `ingress_*`), and `helm_values`.

`endpoint` is a **comma separated bootstrap broker list**, not a hostname: a
Kafka client bootstraps from several brokers. That is also why MSK never had a
CNAME to remove, and why it was the template the other four datastores converged
on when the private zone was removed.

```bash
terraform output -json helm_values | jq
```

No password is ever an output. `secret_name` carries the AWS-mandated
`AmazonMSK_` prefix rather than the usual `{name}/password` path, and AWS
requires it to be encrypted with a customer managed CMK — both are service
constraints, not Lerian conventions.
