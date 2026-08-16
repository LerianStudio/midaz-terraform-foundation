# products/product-console/documentdb

DocumentDB for the product-console admin UI. Root stack over
[`_modules/mongodb-documentdb`](../../../_modules/mongodb-documentdb).

One root, one datastore, one state file. See [`../README.md`](../README.md) for
the product-level picture: why this is the only datastore, the
shared-vs-dedicated model, and the full Helm mapping.

| | |
|---|---|
| Module | `../../../_modules/mongodb-documentdb` |
| State key | `aws/products/product-console/documentdb/terraform.tfstate` |
| Creates | `product-console-{env}-docdb` (DocumentDB cluster) |
| Secret | `product-console-{env}-docdb/password` |
| Chart target | `.Values.configmap` (`MONGODB_URI`, `MONGO_HOST`, `MONGO_PORT`, `MONGODB_USER`, `MONGO_PARAMETERS`) |

## Run it

```bash
cd examples/aws/products/product-console/documentdb

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/product-console/documentdb/terraform.tfstate"

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
  true) — depends only on `infra-base/vpc`, so it works from the first apply.
- **the EKS node security group**, matched by `tag:Name = "lerian-{env}-eks-node"`
  with the **plural** `data "aws_security_groups"`, so an absent cluster returns
  an empty list rather than failing the plan.

> `var.subnet_tag_type` (`"database"`) selects the subnets the **cluster is
> placed in**. `product-network` keeps its own default (`"private"`), the subnets
> whose CIDRs become **ingress**. Do not forward one into the other.

The module already carries `check "ingress_is_reachable"`; this root does not
re-assert it.

## Sizing trap

| Trap | Consequence | Where it is caught |
|---|---|---|
| `instance_class` below `db.t3.medium` | The RDS micro/small range **does not exist** for DocumentDB | Module precondition, at **plan** time |

`db.t3.medium` is the floor — roughly USD 60/month for one instance. For an admin
console that is the strongest argument in this repository for `mode = "shared"`.

## The chart mixes `MONGODB_*` and `MONGO_*`

`helm_values` emits `MONGODB_URI`, `MONGO_HOST`, `MONGO_PORT`, `MONGODB_USER`
and `MONGO_PARAMETERS`. The inconsistent prefixes are the **chart's**, verified
in `values.yaml:226-233`; every sibling chart spells the DB-suffixed ones
`MONGO_NAME` / `MONGO_USER` / `MONGO_PASSWORD`. Do not normalise them.

`MONGODB_URI` is the connection **scheme**, not a connection string, despite what
`templates/NOTES.txt` claims — no template implements a full-URI mode. `mongodb`
is the only correct value: DocumentDB publishes no SRV records.

`MONGODB_DB_NAME` is **not** emitted. DocumentDB creates a database lazily on
first write, so Terraform never creates it and must not guess it. The chart
default `midaz-console` is correct.

## `MONGO_PARAMETERS`

Emitted with no leading `?` (the application appends the separator):

- `retryWrites=false` — **mandatory**. DocumentDB does not implement retryable
  writes and drivers enable them by default, so omitting it makes every write
  fail.
- `tls=true` — only when `documentdb_tls = "enabled"`.

The chart's documented DocumentDB recipe (`docs/UPGRADE-2.0.md:93`) adds
`tlsInsecure=true` and `directConnection=true`. Neither is emitted:
`tlsInsecure` disables certificate validation outright and exists only because
the older wiring put a private CNAME in front of the cluster — this repository
has no private zone, so validation passes on its own merits. `directConnection`
is a topology decision that becomes wrong as soon as `instances_count > 1`.

## TLS is a documented gap

The host side is already correct — `MONGO_HOST` is the raw
`*.docdb.amazonaws.com` endpoint the certificate covers. The blocker is the CA
bundle, and **this chart has no `MONGO_TLS_CA_CERT` variable at all** (the
sibling `reporter` and `plugin-fees` charts do). See
`envs/prd.tfvars-example` for the full note.

## Outputs

Seven uniform contract names — `mode`, `endpoint`, `port`, `security_group_id`,
`secret_arn`, `secret_name`, `identifier` — plus `reader_endpoint`, `arn`,
`kms_key_arn`, `master_username`, `tls_enabled`, the cross-stack context
(`vpc_name`, `eks_cluster_name`, `ingress_*`), and `helm_values`.

```bash
terraform output -json helm_values | jq
```

No password is ever an output. `secret_name` is what an External Secrets
Operator `ExternalSecret` references to populate `secrets.MONGODB_PASS` — a key
the chart base64-encodes itself, and one that is **not** wired to the mongodb
subchart Secret, so it must be supplied explicitly either way.

`reader_endpoint` is published but unused: the chart has no read-only Mongo
variable.

## Shared mode

`mode = "shared"` creates nothing and plans to zero resources. The module
resolves `shared-{env}-docdb` with `data "aws_rds_cluster"` — the AWS provider
ships no `data "aws_docdb_cluster"` at all — and the secret
`shared-{env}-docdb/password`. `endpoint`, `port` and `reader_endpoint` then come
from the resolved cluster. `security_group_id` comes back `null`.

`master_username` is the one value that is still *declared* rather than read, so
keep it equal to the shared tier's (both default to `docdbadmin`).

Every sizing variable in the tfvars is ignored in that mode.
