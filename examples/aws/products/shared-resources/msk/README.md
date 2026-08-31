# products/shared-resources/msk

The **shared Kafka tier**: one MSK cluster per environment, owned by
`product = "shared"`, consumed by any number of products.

| | |
| --- | --- |
| Module | [`_modules/streaming-msk`](../../../_modules/streaming-msk) |
| Creates | `shared-{env}-msk` |
| Secret | `AmazonMSK_shared-{env}-msk` — the prefix is an **AWS requirement** |
| A consumer resolves it with | `data "aws_msk_cluster"` on `shared-{env}-msk` |
| State key | `aws/products/shared-resources/msk/terraform.tfstate` |
| dev cost | `kafka.t3.small` × 3 — **~USD 105/month** |

**This is the directory most clients should not apply.** Streaming is off by
default in the Lerian charts (`STREAMING_ENABLED` defaults to `"false"`, and the
key is not even present in `values.yaml` — the `false` lives in the templates),
so applying this buys USD 105/month of idle broker for a feature nobody turned
on. There is deliberately no `products/midaz/msk` directory for the same reason:
a product that turns streaming on consumes **this** tier with `mode = "shared"`.

Applying this directory is what enables the tier; there is no `msk_enabled`
toggle. Read [`../README.md`](../README.md) for the trade-offs.

---

## Why three brokers is the floor

MSK requires `number_of_broker_nodes` to be a **multiple of the number of client
subnets**, and the module asserts it at plan time. `infra-base/vpc` tags three
subnets `Type=database`, so the valid values are **3, 6, 9**. `kafka.t3.small`
is the smallest broker AWS offers, and the service minimum is two brokers —
reachable only by narrowing `subnet_ids` to exactly two subnet ids, which cannot
be written into a `tfvars-example` because the ids are generated.

`storage_mode = "TIERED"` is **rejected by the `kafka.t3.*` family**, which is
why the dev example leaves it empty.

---

## MSK was the template for the whole shared model

A Kafka client bootstraps from a comma separated broker list, so there was never
a single host to alias behind a CNAME. `streaming-msk` resolved its shared
cluster with `data "aws_msk_cluster"` on the derived name from the start; the
other four datastores converged on the same shape when the private zone was
removed. *Resolve the shared tier by name* is now the one rule, with no
exception to remember.

---

## `mode` is pinned to `dedicated`, and that is not a bug

This stack **creates**. `var.mode` answers *"does this module CREATE or
RESOLVE?"*, not *"is this shared?"*. There is no `mode` variable in this root.
See the header of [`main.tf`](main.tf).

`product` is pinned to `"shared"` by validation, because `shared-{env}-msk` and
`AmazonMSK_shared-{env}-msk` **are** the discovery contract.

---

## How a product consumes it

```hcl
module "streaming" {
  source = "../../../_modules/streaming-msk"

  product     = "midaz"
  environment = var.environment
  mode        = "shared" # resolves shared-{env}-msk + AmazonMSK_shared-{env}-msk
}
```

The consumer creates nothing and gets `security_group_id = null` — opening the
cluster is this stack's job.

A shared Kafka cluster is **one topic namespace**, one set of ACLs and one
retention budget. `auto_create_topics_enable` stays `false` so a collision is
impossible to create by accident: the Lerian charts create their topics
explicitly from an ArgoCD PreSync `rpk` job, versioned with the service that
owns them. Per-product SCRAM users and ACLs are created against the cluster
itself, outside Terraform — the module creates one user.

---

## Open item: `STREAMING_BROKERS` does not exist in the chart

Unlike the other four datastores in this tier, **there is currently no chart
variable that carries a Kafka broker address.** The midaz chart (8.7.0,
appVersion 3.8.0) defines exactly three streaming variables:
`STREAMING_ENABLED`, `STREAMING_SASL_PASSWORD` and `STREAMING_TLS_CA_CERT`.

Until the chart grows one, the bootstrap list has to be injected through
`ledger.extraEnvVars` / `crm.extraEnvVars`. The `helm_values` output emits
`STREAMING_BROKERS` anyway, under the name the module README already uses, so
that the day the chart adds it the wiring is a rename rather than a discovery
exercise.

---

## Ingress

| Source | Variable | Default | Depends on |
| --- | --- | --- | --- |
| `Type=private` subnet CIDRs | `allow_private_subnet_cidr_ingress` | `true` | `infra-base/vpc` |
| EKS node security group | `eks_node_security_group_lookup_enabled` | `true` | `infra-base/eks` |
| Anything else | `allowed_security_group_ids`, `allowed_cidr_blocks` | `[]` | — |

This matters more on MSK than anywhere else: the module used to ship **no
VPC-CIDR fallback at all**, so empty allow lists produced a cluster with zero
ingress that looked healthy and accepted no connections. It now carries
`check "ingress_is_reachable"`.

---

## Init and apply

```bash
cd examples/aws/products/shared-resources/msk

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/shared-resources/msk/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

---

## Outputs

The seven uniform contract names, plus `bootstrap_brokers_sasl_scram`,
`bootstrap_brokers_tls`, `bootstrap_brokers`, `zookeeper_connect_string`,
`cluster_arn`, `cluster_uuid`, `configuration_arn`, `kms_key_arn`,
`scram_kms_key_arn`, `log_group_arn`, `helm_values`, and the four context
outputs.

`endpoint` is a comma separated **bootstrap broker list** for the strongest
enabled auth mode, not a hostname. `port` (9096 SASL/SCRAM, 9094 TLS, 9092
plaintext) is already embedded in it.

---

## Validation

```bash
terraform fmt -check -recursive .
terraform init -backend=false -input=false
terraform validate
```
