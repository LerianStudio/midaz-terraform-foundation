# products/plugin-fees/documentdb

DocumentDB for the plugin-fees fee engine — its only required datastore. Root
stack over [`_modules/mongodb-documentdb`](../../../_modules/mongodb-documentdb).

One root, one datastore, one state file. Its sibling
[`../msk`](../msk) is independent and **optional**. See
[`../README.md`](../README.md) for the product-level picture.

| | |
|---|---|
| Module | `../../../_modules/mongodb-documentdb` |
| State key | `aws/products/plugin-fees/documentdb/terraform.tfstate` |
| Creates | `plugin-fees-{env}-docdb` (DocumentDB cluster) |
| Secret | `plugin-fees-{env}-docdb/password` |
| Chart target | `.Values.fees.configmap` (`MONGO_URI`, `MONGO_HOST`, `MONGO_PORT`, `MONGO_USER`, `MONGO_PARAMETERS`) |

## Run it

```bash
cd examples/aws/products/plugin-fees/documentdb

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/plugin-fees/documentdb/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

`../../../` is **three** levels up and lands on `examples/aws`. Verified with
`terraform init`.

Prerequisites: `infra-base/vpc`. `infra-base/eks` is optional at apply time.

## What this root decides

1. **Derive the cross-stack names.** `lerian-{env}-vpc` and `lerian-{env}-eks` —
   the `lerian` prefix is why this root does not call the `naming` module.
2. **Compute the ingress allow list.**
3. **Translate to the chart.** The `helm_values` output.

It creates no AWS resource of its own.

## Ingress

Performed by
[`_modules/product-network`](../../../_modules/product-network), called here as
`module.network` with `enabled = var.mode == "dedicated"`.

- **`Type=private` subnet CIDRs** (`allow_private_subnet_cidr_ingress`, default
  true) — depends only on `infra-base/vpc`.
- **the EKS node security group**, matched by `tag:Name = "lerian-{env}-eks-node"`
  with the **plural** `data "aws_security_groups"`.

> `var.subnet_tag_type` (`"database"`) selects the subnets the **cluster is
> placed in**. `product-network` keeps its own default (`"private"`), the subnets
> whose CIDRs become **ingress**.

The module already carries `check "ingress_is_reachable"`.

## Sizing trap

| Trap | Consequence | Where it is caught |
|---|---|---|
| `instance_class` below `db.t3.medium` | The RDS micro/small range **does not exist** for DocumentDB | Module precondition, at **plan** time |

`db.t3.medium` is the floor — roughly USD 60/month for one instance.

## The unsuffixed `MONGO_*` family

`helm_values` emits `MONGO_URI`, `MONGO_HOST`, `MONGO_PORT`, `MONGO_USER` and
`MONGO_PARAMETERS`, verified against `templates/fees/configmap.yaml:25-34` in
chart 7.3.0. Host and port are **separate**; nothing is concatenated.

This is not midaz's `MONGO_ONBOARDING_*` / `MONGO_TRANSACTION_*` pair, and not
product-console's `MONGODB_USER` hybrid. Three charts, three spellings.

`MONGO_URI` is the connection **scheme**, not a connection string — the chart
ships the bare word `mongodb`, which is also the only value that works for
DocumentDB, since it publishes no SRV records.

`MONGO_NAME` is **not** emitted. The chart default is `plugin-fees-db`;
DocumentDB creates databases lazily on first write, so Terraform never creates it
and must not guess it.

`MONGO_USER` is the DocumentDB **master** (`docdbadmin`), not the chart's
least-privilege default `plugin-fees` — that one is created by the chart's
optional bootstrap Job (`global.externalMongoDefinitions.enabled`, default
false), not by Terraform.

## `MONGO_PARAMETERS`

Emitted with no leading `?`:

- `retryWrites=false` — **mandatory**. DocumentDB does not implement retryable
  writes and drivers enable them by default.
- `tls=true` — only when `documentdb_tls = "enabled"`.

> **CONFIRMAR no chart:** whether the fee engine joins `MONGO_PARAMETERS` onto
> the connection string with a leading `?` or expects one already present. The
> chart default is the empty string and no template concatenates it, so the chart
> cannot answer this.

## TLS

Better positioned than product-console: this chart **does** expose
`MONGO_TLS_CA_CERT` (`configmap.yaml:32`), so there is somewhere to mount the
global RDS CA bundle. Terraform does not distribute that bundle, so flipping
`documentdb_tls` to `"enabled"` is a two-sided change. See
`envs/prd.tfvars-example`.

## Outputs

Seven uniform contract names — `mode`, `endpoint`, `port`, `security_group_id`,
`secret_arn`, `secret_name`, `identifier` — plus `reader_endpoint`, `arn`,
`kms_key_arn`, `master_username`, `tls_enabled`, the cross-stack context
(`vpc_name`, `eks_cluster_name`, `ingress_*`), and `helm_values`.

```bash
terraform output -json helm_values | jq
```

No password is ever an output. `secret_name` populates `MONGO_PASSWORD` via
External Secrets — but only takes effect with `mongodb.enabled = false` and
`mongodb.external = true`, because the chart otherwise reads the password from
the Bitnami subchart's Secret.

`reader_endpoint` is published but unused: the chart has no read-only Mongo
variable today.

## Shared mode

`mode = "shared"` creates nothing and plans to zero resources. The module
resolves `shared-{env}-docdb` with `data "aws_rds_cluster"` — the AWS provider
ships no `data "aws_docdb_cluster"` at all — and the secret
`shared-{env}-docdb/password`. `security_group_id` comes back `null`.

`master_username` is still *declared* rather than read, so keep it equal to the
shared tier's (both default to `docdbadmin`).

Every sizing variable in the tfvars is ignored in that mode.
