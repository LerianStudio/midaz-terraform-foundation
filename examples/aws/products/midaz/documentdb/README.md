# products/midaz/documentdb

MongoDB-compatible storage for the midaz ledger and CRM. Root stack over
[`_modules/mongodb-documentdb`](../../../_modules/mongodb-documentdb).

One root, one datastore, one state file. See [`../README.md`](../README.md) for
the product-level picture: deploy order, the shared-vs-dedicated model, and the
full Helm mapping.

| | |
|---|---|
| Module | `../../../_modules/mongodb-documentdb` |
| State key | `aws/products/midaz/documentdb/terraform.tfstate` |
| Creates | `midaz-{env}-docdb` (DocumentDB cluster) |
| Secret | `midaz-{env}-docdb/password` |
| Chart target | `ledger.configmap` (`MONGO_ONBOARDING_*`, `MONGO_TRANSACTION_*`), `crm.configmap` (`MONGO_*`) |

The AWS suffix is `docdb` and the chart variables say `MONGO`. Intentional —
`docdb` is the service, `mongodb` is what the applications speak. Both sides of
the contract agree on it; do not "fix" one of them.

## Run it

```bash
cd examples/aws/products/midaz/documentdb

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/midaz/documentdb/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

`../../../` is **three** levels up and lands on `examples/aws`, where both
`backend/` and `_modules/` live. Verified with `terraform init`.

Prerequisites: `infra-base/vpc`. `infra-base/eks` is optional at apply time —
see *Ingress* below.

## What this root decides

The module already resolves the VPC and the subnets by itself. This root exists
for three things the module cannot do:

1. **Derive the cross-stack names.** `lerian-{env}-vpc` and `lerian-{env}-eks`.
   Note the `lerian` prefix on both: they belong to `infra-base`, not to midaz.
   That is also why this root does **not** call the `naming` module.
2. **Compute the ingress allow list.**
3. **Translate to the chart** — including the TLS parameters below.

It creates no AWS resource of its own.

## Ingress

Identical to the sibling roots, because it is literally the same code: resolved
by [`_modules/product-network`](../../../_modules/product-network), called here
as `module.network` with `enabled = var.mode == "dedicated"`. `Type=private`
subnet CIDRs plus the EKS node security group, matched by
`tag:Name = "lerian-{env}-eks-node"`; `check "eks_node_security_group_resolved"`
lives in that module and warns while the lookup is empty. See its README for the
plural-data-source rule and the deploy-order window it covers.

> `var.subnet_tag_type` (`"database"`) selects the subnets the **cluster is
> placed in** and goes to `mongodb-documentdb` only. `product-network` keeps its
> own default (`"private"`), the subnets whose CIDRs become **ingress**.

The "nothing can reach this cluster at all" case is **not** re-asserted here: the
module already carries `check "ingress_is_reachable"` for it.

## Sizing

`db.t3.medium` is the **smallest class DocumentDB offers**. There is no micro and
no small — the RDS burstable range below medium simply does not exist for this
service, and the module rejects those values with a plan-time precondition rather
than five minutes into the apply.

That makes this the most expensive of the four midaz datastores in dev: roughly
USD 60/month for one instance, more than the dev PostgreSQL and Valkey combined.
If that is not acceptable, `mode = "shared"` consumes the cluster owned by
`products/shared-resources/documentdb` and costs nothing.

`instances_count = 1` means no failover: an AZ loss takes the cluster down.
Correct in dev, wrong anywhere else.

## TLS is the interesting decision

`documentdb_tls` is `"disabled"` in all three environments, matching
`products/shared-resources/documentdb`. That is a **documented gap**, spelled out in
`envs/prd.tfvars-example`, not an oversight. One thing has to land first: the
chart has to mount the global RDS CA bundle and set
`MONGO_ONBOARDING_TLS_CA_CERT` / `MONGO_TRANSACTION_TLS_CA_CERT`. Terraform does
not distribute that bundle and cannot.

**The host side is already settled.** `MONGO_*_HOST` is always the raw
`endpoint`, the `*.docdb.amazonaws.com` name the certificate actually covers, so
turning TLS on is a one-line change: `documentdb_tls = "enabled"` appends
`tls=true` to `MONGO_*_PARAMETERS` and nothing about the host moves. (An alias in
front of the writer endpoint would fail hostname validation on every modern
driver, which is why none is published.) The standing cost is that a cluster
replacement changes `MONGO_*_HOST` and is therefore a Helm values change.

## `MONGO_*_URI` is a scheme, not a URI

The chart does **not** build a connection string. `MONGO_ONBOARDING_URI`,
`MONGO_TRANSACTION_URI` and `MONGO_URI` carry the scheme alone; host, port, user
and database name are separate variables and the application assembles them.

`"mongodb"` is the only correct value for DocumentDB. It publishes no SRV
records, so `mongodb+srv` cannot resolve.

## `retryWrites=false` is mandatory

`helm_values` emits `MONGO_*_PARAMETERS = "retryWrites=false"` (plus `tls=true`
when TLS is on). DocumentDB does not implement retryable writes and every driver
enables them by default, so omitting this makes every write fail.

> Left to confirm against the chart: whether the ledger joins
> `MONGO_*_PARAMETERS` onto the connection string with a leading `?` or expects
> one already present. The emitted value carries no separator. The same note is
> in `outputs.tf`.

## Database names are not emitted

`MONGO_*_NAME` is deliberately absent from `helm_values`. DocumentDB creates a
database lazily on first write, so Terraform never creates `onboarding`,
`transaction` or `crm` and must not claim to know them. The chart defaults are
correct; leave them alone.

## CRM

The unsuffixed `MONGO_HOST` / `MONGO_PORT` / `MONGO_USER` / `MONGO_URI` /
`MONGO_PARAMETERS` belong to the CRM deployment (`crm.enabled`, **false** by
default). They are emitted regardless, so enabling CRM needs no second lookup and
they are harmless while it is off.

`reader_endpoint` is published but unused — the chart has no read-only Mongo
variable today. It exists for operators and for the day one appears.

## Outputs

Seven uniform contract names shared with every other Lerian datastore root —
`mode`, `endpoint`, `port`, `security_group_id`, `secret_arn`, `secret_name`,
`identifier` — plus `reader_endpoint`, `arn`, `kms_key_arn`, `master_username`,
`tls_enabled`, the cross-stack context, and `helm_values`.

`endpoint` is the raw DocumentDB writer endpoint in both modes, and
`reader_endpoint` the raw reader endpoint. There is no `dns_name`: the cluster
certificate covers `*.docdb.amazonaws.com` only.

`master_username` is read from the stack variable rather than from the module
output. The module marks its copy `sensitive`, and referencing it would redact
the entire `helm_values` map and defeat the handoff.

## Shared mode

`mode = "shared"` creates nothing and plans to zero resources. Every lookup is
gated on `mode == "dedicated"`. The module resolves the cluster
`shared-{env}-docdb` and the secret `shared-{env}-docdb/password` by name, so
`endpoint`, `reader_endpoint`, `port` and `master_username` come from the
resolved cluster. `security_group_id` comes back `null`.

The cluster lookup is `data "aws_rds_cluster"`, not a docdb-specific one: the AWS
provider ships **no** `data "aws_docdb_cluster"` — only `docdb_engine_version`
and `docdb_orderable_db_instance` — because DocumentDB clusters are first-class
DB clusters in the RDS control plane. Verified against a real account: the data
source returns `engine = "docdb"` alongside the endpoints, the port and the
master username.

The name is fully derived, so this root exposes no variable for it. The module's
own `shared_identifier` is the escape hatch for a shared cluster that is not
called `shared-{env}-docdb`.
