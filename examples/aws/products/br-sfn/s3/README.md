# products/br-sfn/s3

**OPT-IN — apply only if the `correios` rail is enabled.** Object storage for
the correspondence attachments the correios rail exchanges with the Brazilian
Central Bank. Root stack over
[`_modules/s3-bucket`](../../../_modules/s3-bucket).

One root, one datastore, one state file. See [`../README.md`](../README.md) for
the product-level picture.

| | |
|---|---|
| Module | `../../../_modules/s3-bucket` |
| State key | `aws/products/br-sfn/s3/terraform.tfstate` |
| Creates | `br-sfn-{env}-correios-attachments-{account_id}` + IRSA role + per-bucket IAM policy |
| Chart target | **`correios.configmap`** |
| Gated by | `correios.enabled` (chart default **`false`**, `values.yaml:604`) |

## Why this root exists — the chart names none of these keys

This is the part worth reading before assuming the directory is a mistake. A
grep for `OBJECT_STORAGE` across the whole `br-sfn` chart returns **two hits,
both commented out**, in a file Helm never renders. The dependency is real
anyway, and here is the evidence chain:

| # | Evidence | Where |
|---|---|---|
| 1 | *"Postgres + Valkey/Redis cache + RabbitMQ + **S3-compatible object storage**, all external."* | `br-sfn/values.yaml:590-592` |
| 2 | *"Stores attachments in S3-compatible object storage"* / *"Requires external Postgres, Valkey/Redis cache, RabbitMQ, and S3-compatible storage"* | `br-sfn/docs/UPGRADE-1.1.md:25,27` |
| 3 | The rail runs **the same image** as the standalone product: `ghcr.io/lerianstudio/plugin-bc-correios` | `br-sfn/values.yaml:608` vs `plugin-bc-correios/values.yaml:70` |
| 4 | That binary genuinely consumes S3 — the standalone chart hardcodes `OBJECT_STORAGE_PROVIDER/_ENDPOINT/_BUCKET/_PATH_STYLE`, and its init container **blocks startup** until the endpoint answers | `plugin-bc-correios/templates/configmap.yaml:47-51`, `deployment.yaml:88-89` |
| 5 | `OBJECT_STORAGE_ENDPOINT` and `OBJECT_STORAGE_BUCKET` appear under `correios.configmap` in the operator skeleton — commented out, and that file is never rendered | `br-sfn/values-template.yaml:75-76` |

### So why does no template name them?

Because `correios.configmap` is an **untyped passthrough**, by explicit design.
`br-sfn.componentConfigData` does `mergeOverwrite` + `toYaml`
(`templates/_helpers.tpl:75-82`), the result becomes the component ConfigMap
(`:117-129`), and that reaches the container through `envFrom` (`:248-260`).
`values.schema.json` declares `correios.configmap` as bare `{"type":"object"}`
with `additionalProperties: true` — there is no allowlist to be absent from.

The commit that introduced the rail states the intent outright: the predecessor
chart used *"a FIXED ALLOWLIST of 40 keys … anything off the list vanished
silently. **br-sfn emits the map verbatim.**"*

**Verdict: a real dependency that the chart declines to type — not residue from
a copied template.** That is why this root was created rather than the finding
merely recorded.

### `values-template.yaml` is documentation, and incomplete documentation

It is an operator skeleton the repository validator requires
(`helm/.github/scripts/validate-helm-charts/main.go:270-272`); the chart uses
`.Files` nowhere, so Helm never reads it. It lists only `_ENDPOINT` and
`_BUCKET`, while the same binary also reads `OBJECT_STORAGE_PROVIDER` and
`OBJECT_STORAGE_PATH_STYLE`, plus the credential pair
`OBJECT_STORAGE_ACCESS_KEY` / `OBJECT_STORAGE_SECRET_KEY`. `helm_values` emits
all four config keys, because the binary is the contract and the skeleton is
not.

`br-sfn/README.md:89-92`, the Chart Contract table, lists `POSTGRES_PASSWORD` as
the only per-rail required secret for correios and never mentions object storage
at all. Chart-side gap; reported, not worked around.

## Run it

```bash
cd examples/aws/products/br-sfn/s3

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/br-sfn/s3/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

`../../../` is **three** levels up and lands on `examples/aws`. Verified with
`terraform init -backend=false`.

**Prerequisite: `infra-base/eks`, and it is harder than the datastore roots'.**
With `irsa_enabled = true` (the default) the OIDC provider is resolved through
two **singular** data sources, which fail the plan when the cluster does not
exist — deliberately, because an IRSA role attached to a provider that is not
there applies cleanly and produces pods that cannot reach the bucket. The
datastore roots tolerate a missing cluster because their security-group lookup
is plural.

## This root is shaped differently from its siblings

Three contract points that hold for `postgres/`, `valkey/`, `rabbitmq/` and
`msk/` do not hold here. Each is a property of S3, not an omission:

| | Datastore roots | This root |
|---|---|---|
| `var.mode` | `dedicated` \| `shared` | **absent** — no shared bucket tier exists, so `_modules/s3-bucket` has no `mode` input. The `mode` *output* is the constant `"dedicated"` so `terraform output mode` stays uniform |
| Ingress / security group / subnets | resolved via `product-network` | **absent** — S3 is a regional API endpoint, not a host in the VPC. Access is IAM, and `product-network` is called with `enabled = false` purely to derive the cluster name |
| Seven uniform outputs | `endpoint`, `port`, `security_group_id`, `secret_arn`, `secret_name`, `identifier`, `mode` | only `mode`. Emitting the other six as `null` would leave a consumer unable to distinguish *"no endpoint exists"* from *"the lookup failed"* |

## The IRSA grant is broader than the correios rail

**Read this before production.** br-sfn defines **one chart-level
ServiceAccount shared by every component** — the helper is literally commented
*"Name of the service account to use (shared by every component)"*
(`templates/_helpers.tpl:33-38`), with `serviceAccount.create` defaulting to
`true` (`values.yaml:31-34`).

There is no per-rail ServiceAccount, so the role this root creates is assumable
by `spb`, `spi`, `siloc`, `scr`, `slc-edge`, `desk` and `cockpit` as well as
`correios`. For a BACEN-correspondence bucket that may not be acceptable.

The chart offers no narrower option. The two ways out:

- set `irsa_enabled = false` and attach `iam_policy_arns` to a role the EKS
  stack scopes however it likes; or
- raise per-rail ServiceAccounts as a chart change.

Recorded here rather than papered over.

## The logical bucket name differs from the standalone root

| Root | Logical key | Real bucket |
|---|---|---|
| `products/plugin-bc-correios/s3` | `bc-correios-attachments` | `plugin-bc-correios-{env}-bc-correios-attachments-{account}` |
| **this one** | `correios-attachments` | `br-sfn-{env}-correios-attachments-{account}` |

Deliberate: the component is called `correios` everywhere in br-sfn — values
key, template directory, ConfigMap name — so the bucket follows the vocabulary
of the chart it belongs to. The real names differ regardless, because the
product prefix does, so the two never collide and **nothing migrates
automatically between them**. Moving a deployment from the standalone chart to
the monorepo rail is a data copy, not a rename.

## Helm handoff

Everything lands on `.Values.correios.configmap`.

| Terraform | Chart env var |
|---|---|
| literal `"s3"` | `OBJECT_STORAGE_PROVIDER` |
| `bucket_name` | `OBJECT_STORAGE_BUCKET` |
| `https://s3.{region}.amazonaws.com` | `OBJECT_STORAGE_ENDPOINT` |
| literal `"false"` | `OBJECT_STORAGE_PATH_STYLE` |

```bash
terraform output -json helm_values | jq
```

Then annotate the chart ServiceAccount:

```yaml
serviceAccount:
  annotations:
    eks.amazonaws.com/role-arn: <iam_role_arn>
```

**`OBJECT_STORAGE_ENDPOINT` must be explicit.** In the standalone chart an empty
value falls back to the in-cluster SeaweedFS service through a
`default (printf …)`. Here there is no template to apply a default, so empty is
emitted as an empty string and what the binary does with that is undefined by
the chart. Either way, empty is **not** "let the SDK resolve the endpoint".

**No SeaweedFS to disable.** The standalone root has to pair its values with
`seaweedfs.enabled = false`. br-sfn ships no SeaweedFS resources at all — a grep
for `SEAWEED` across the whole tree returns zero hits — so there is nothing to
switch off.

### Two open `CONFIRMAR`s

Both are inherited from the standalone root, and neither blocks an apply:

1. **Region.** This rail has no `OBJECT_STORAGE_REGION` key, unlike `reporter`
   and `fetcher`. With IRSA the EKS pod identity webhook injects `AWS_REGION`
   and `AWS_DEFAULT_REGION`, which is normally enough. If the application needs
   it explicitly, add `AWS_REGION` to `correios.configmap` — the passthrough
   accepts it with no chart change — using the `region` output of this stack.
2. **Credential fallback.** Does the application fall back to the AWS default
   credential chain when `OBJECT_STORAGE_ACCESS_KEY` and
   `OBJECT_STORAGE_SECRET_KEY` are empty? IRSA depends on it. Note the spelling:
   `OBJECT_STORAGE_ACCESS_KEY`, without the `_ID` suffix `reporter` uses.

## Retention

| Env | IA | Glacier | Expiration | `force_destroy` |
|---|---|---|---|---|
| dev | 30d | — | 90d | **true** |
| stg | 30d | 90d | 365d | false |
| prd | 30d | 180d | **1825d (5y)** | false |

The prd figure matches `products/plugin-bc-correios/s3` because it is the same
data. **Confirm it against the retention BACEN actually requires before the
first production write** — shortening it later does not bring back an expired
object.

`kms_key_arn` is `null` in every environment. The module supports SSE-KMS and
extends the bucket IAM policy with the matching `kms:*` actions when a key is
given, but it does not create the key and this repository provisions no CMK for
S3. Until one exists the bucket uses SSE-S3 (AES256) with Bucket Keys, which is
the module default and is not "unencrypted". See `envs/prd.tfvars-example`.
