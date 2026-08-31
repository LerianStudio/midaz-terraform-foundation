MongoDB-compatible store for the plugin-br-pix-switch DICT hub — **one** of the
chart's ten components uses it. Root stack over
[`_modules/mongodb-documentdb`](../../../_modules/mongodb-documentdb).

One root, one datastore, one state file. See [`../README.md`](../README.md) for
the product-level picture: deploy order, the shared-vs-dedicated model, and the
full Helm mapping.

| | |
|---|---|
| Module | `../../../_modules/mongodb-documentdb` |
| State key | `aws/products/plugin-br-pix-switch/documentdb/terraform.tfstate` |
| Creates | `plugin-br-pix-switch-{env}-docdb` (DocumentDB cluster) |
| Secret | `plugin-br-pix-switch-{env}-docdb/password` |
| Chart target | `dictHub.secrets.MONGO_URL` (a **secret**) + `global.externalMongoDefinitions` |
| Chart verified | plugin-br-pix-switch 2.0.0-beta.1+ |

The AWS suffix is `docdb` and the chart variables say `MONGO`. Intentional —
`docdb` is the service, `mongodb` is what the applications speak. Both sides of
the contract agree on it; do not "fix" one of them.

## Run it

```bash
cd examples/aws/products/plugin-br-pix-switch/documentdb

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/plugin-br-pix-switch/documentdb/terraform.tfstate"

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
   Note the `lerian` prefix on both: they belong to `infra-base`, not to plugin-br-pix-switch.
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

That makes this the most expensive of the four plugin-br-pix-switch datastores in dev: roughly
USD 60/month for one instance, more than the dev PostgreSQL and Valkey combined.
If that is not acceptable, `mode = "shared"` consumes the cluster owned by
`products/shared-resources/documentdb` and costs nothing.

`instances_count = 1` means no failover: an AZ loss takes the cluster down.
Correct in dev, wrong anywhere else.

## TLS is the interesting decision

`documentdb_tls` is `"disabled"` in all three environments, matching
`products/shared-resources/documentdb`. That is a **documented gap**, spelled out in
`envs/prd.tfvars-example`, not an oversight. **Two** things have to land first,
and this chart adds the second one:

1. The application needs the global RDS CA bundle. This chart has **no key for
   it at all** — no `MONGO_TLS_CA_CERT`, nothing — because its whole Mongo
   surface is the one `MONGO_URL` secret. Distributing the bundle is a chart
   change, and Terraform cannot do it either way.
2. The chart's own **Mongo bootstrap Job** runs `mongosh --host --port` with no
   `--tls` flag (`templates/bootstrap-mongodb.yaml`). It stops working the moment
   the cluster requires TLS.

**The host side is already settled.** The URL host is always the raw `endpoint`,
the `*.docdb.amazonaws.com` name the certificate actually covers, so turning TLS
on moves nothing about the host: `documentdb_tls = "enabled"` simply appends
`tls=true` to `mongo_parameters`. (An alias in front of the writer endpoint would
fail hostname validation on every modern driver, which is why none is published.)
The standing cost is that a cluster replacement changes the host and is therefore
a values change.

## The chart consumes a URL, not host/port — so `helm_values` looks different

**This is the structural difference from every other product.** Read it before
copying anything from `products/midaz/documentdb`.

The chart reads Mongo through **one key**, on **one component**, and it is a full
connection URL in a Secret:

```yaml
dictHub:
  secrets:
    MONGO_URL: "mongodb://user:<password>@mongo-host:27017/?authSource=admin"
```
(`values-template.yaml:87`)

There is no `MONGO_HOST`, no `MONGO_PORT`, no `MONGO_USER`, and none of the
`MONGO_ONBOARDING_*` / `MONGO_TRANSACTION_*` families midaz uses.
`dictHub.secrets` is emitted verbatim into a Secret and that is the whole
contract.

Terraform cannot fill a secret, so this root publishes:

1. **`helm_values`** — the non-secret surface the bootstrap Job reads, keyed by
   **Helm value path**:

   | Path | Value |
   |---|---|
   | `global.externalMongoDefinitions.connection.host` | `endpoint` |
   | `global.externalMongoDefinitions.connection.port` | `port` |
   | `global.externalMongoDefinitions.mongoAdminLogin.username` | `master_username` |

2. **`mongo_url_template`** — the `MONGO_URL` with the password as the literal
   placeholder `<password>`, and **the query string corrected** (see below).

3. **`mongo_parameters`** — that query string on its own, so an operator
   assembling the URL by hand cannot drop it.

## The chart's own `MONGO_URL` example is wrong for DocumentDB

`values-template.yaml:87` shows:

```
mongodb://user:<password>@mongo-host:27017/?authSource=admin
```

Two parameters are missing, and both are properties of DocumentDB rather than
client preferences:

- **`retryWrites=false` — mandatory.** DocumentDB does not implement retryable
  writes and every modern driver enables them **by default**. Without it the
  connection succeeds and **every write fails**, which reads like an application
  bug rather than a connection-string bug. This is the single most expensive
  omission on the page.
- **`tls=true`** — mirrors the cluster `tls` parameter. Appended only when
  `documentdb_tls = "enabled"`.

`mongo_url_template` emits both. `authSource=admin` is kept from the chart's
example and is correct: DocumentDB creates every user in `admin`, and the
bootstrap Job authenticates the same way.

`mongodb://`, not `mongodb+srv://` — DocumentDB publishes no SRV records, so the
`+srv` form cannot resolve.

## The Mongo bootstrap Job, and two things to check against it

The chart ships `templates/bootstrap-mongodb.yaml`, off by default, which creates
the **application** user (`pixswitch`) with `readWrite` on `pix-dict` — and on
`pix-cob`, which is a forward-compat slot nothing reads today
(`values.yaml:117-120`). It authenticates as the root user with
`--authenticationDatabase admin`.

> **The root username is a real trap.** The chart defaults
> `global.externalMongoDefinitions.mongoAdminLogin.username` to **`root`**
> (`values.yaml:109`); the DocumentDB master username created here defaults to
> **`docdbadmin`**. They must match or the Job cannot authenticate. `helm_values`
> emits the Terraform value for exactly that key so the two cannot drift.

> **CONFIRMAR:** the Job runs `mongosh --host --port` with **no `--tls` flag**. That
> works only while the cluster's `tls` parameter is `disabled`, which is the
> default here and matches `products/midaz/documentdb`. Turning `documentdb_tls`
> on requires a change to that Job *and* a CA bundle for the application — the
> chart has no key for one — so the two have to move together.

## Database names are not emitted

`dictHub.configmap.MONGO_DB_NAME` is `pix-dict` (`values-template.yaml:83`). It
is an application decision, and DocumentDB creates a database lazily on first
write, so Terraform neither creates it nor knows it. The chart default is
correct; leave it alone.

## Outputs

Seven uniform contract names shared with every other Lerian datastore root —
`mode`, `endpoint`, `port`, `security_group_id`, `secret_arn`, `secret_name`,
`identifier` — plus `reader_endpoint`, `arn`, `kms_key_arn`, `master_username`,
`tls_enabled`, the cross-stack context, `helm_values`, `mongo_url_template` and
`mongo_parameters`.

`endpoint` is the raw DocumentDB writer endpoint in both modes, and
`reader_endpoint` the raw reader endpoint. There is no `dns_name`: the cluster
certificate covers `*.docdb.amazonaws.com` only.

`master_username` is read from the stack variable rather than from the module
output. The module marks its copy `sensitive`, and referencing it would redact
the entire `helm_values` map and defeat the handoff.

`reader_endpoint` is published but unused: the chart has one `MONGO_URL` and no
read-only variant.

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
