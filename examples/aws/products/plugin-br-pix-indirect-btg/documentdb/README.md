# products/plugin-br-pix-indirect-btg/documentdb

Message and event persistence for `pix`, `inbound` and `outbound`. Root stack
over [`_modules/mongodb-documentdb`](../../../_modules/mongodb-documentdb).

One root, one datastore, one state file. See [`../README.md`](../README.md) for
the product-level picture.

| | |
|---|---|
| Module | `../../../_modules/mongodb-documentdb` |
| State key | `aws/products/plugin-br-pix-indirect-btg/documentdb/terraform.tfstate` |
| Creates | `plugin-br-pix-indirect-btg-{env}-docdb` (DocumentDB cluster) |
| Secret | `plugin-br-pix-indirect-btg-{env}-docdb/password` |
| Chart target | `pix.configmap`, `inbound.configmap`, `outbound.configmap` |

`reconciliation` and `schedule` have no Mongo configuration and are absent from
`helm_values`.

## Run it

```bash
cd examples/aws/products/plugin-br-pix-indirect-btg/documentdb

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/plugin-br-pix-indirect-btg/documentdb/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

## Split host/port, not a URI

| Terraform | Chart key |
|---|---|
| literal `"mongodb"` | `MONGO_URI` |
| `endpoint` | `MONGO_HOST` |
| `port` | `MONGO_PORT` |
| `master_username` | `MONGO_USER` |
| derived from `documentdb_tls` | `MONGO_TLS` (**pix only**) |
| `secret_name` → External Secrets | `MONGO_PASSWORD` |

`MONGO_URI` is **not** a connection string. The chart default is the bare word
`mongodb` and the application assembles the URI from the surrounding variables —
the midaz shape. `mongodb` is the only correct value for DocumentDB: it
publishes no SRV records, so `mongodb+srv` cannot resolve.

> Do not carry anything over from the sibling product. `plugin-br-bank-transfer`
> is **URI-only**: one `MONGO_URI` in the Secret carrying scheme, credentials,
> host, port and query parameters, with `retryWrites=false` mandatory inside it.
> This chart has no such variable and no place to put query parameters.
>
> **CONFIRMAR com o time:** DocumentDB does not implement retryable writes, and
> drivers enable them by default. With a split host/port contract there is no
> chart key to put `retryWrites=false` in, so either the plugin sets it in code
> or writes will fail. Worth confirming before the first DocumentDB deploy.

## The chart will not render without `MONGO_HOST`

`_helpers.tpl` carries `plugin-br-pix-indirect-btg.mongoHostRequired`, which
`fail()`s per component:

```
ERROR: <component>.configmap.MONGO_HOST is REQUIRED when the bundled mongodb
subchart is disabled or external.
```

and `mongoPasswordRequired` does the same for
`<component>.secrets.MONGO_PASSWORD`.

## `MONGO_TLS` exists on `pix` and nowhere else

`templates/pix/configmap.yaml` has it; `inbound` and `outbound` do not. That is
why the `pix` entry in `helm_values` is a superset rather than the same map three
times — putting `MONGO_TLS` in the other two would write a key into a ConfigMap
the application never reads.

It is also why TLS stays off. See `envs/prd.tfvars-example`: enabling it on the
cluster while two of the three Mongo-speaking components have no way to be told
is a state the chart cannot express. The host side is already correct —
`MONGO_HOST` is always the raw `*.docdb.amazonaws.com` writer endpoint, exactly
what the DocumentDB certificate covers.

## `MONGO_USER` and the bundled subchart disagree by punctuation

The components default to `pix-btg` (hyphen); the bundled subchart's `rootUser`
is `pix_btg` (underscore). Neither is imposed here: `master_username` is the
DocumentDB master account, it defaults to the Lerian-wide `docdbadmin`, and
`helm_values` emits it explicitly so the chart default never applies.

## `MONGO_NAME` is not emitted

The chart default is `pix-btg-db`. DocumentDB creates a database lazily on first
write, so Terraform never creates it and must not claim to know it.

## The bootstrap Job

`templates/bootstrap-mongodb.yaml` runs `mongosh` against the cluster with
`MONGO_ROOT_USER` / `MONGO_ROOT_PASSWORD` and creates or updates an application
user from `MONGO_APP_USER` / `MONGO_APP_PASSWORD`, with roles parsed from
`ROLES_JSON`, against the `admin` database.

> **CONFIRMAR com o time:** whether that Job is expected to run against
> DocumentDB. DocumentDB implements a restricted subset of MongoDB's role model,
> so a `ROLES_JSON` written for the bundled Bitnami MongoDB may be rejected.
> Terraform creates the master user only; any application user is the Job's or
> an operator's to create.

## Sizing

| Env | Class | Instances | Notes |
|---|---|---|---|
| dev | `db.t3.medium` | 1 | ~USD 60/month — the SMALLEST class the service offers |
| stg | `db.t3.medium` | 2 | exercises failover and the reader endpoint |
| prd | `db.r6g.large` | 3 | one per AZ, deletion protection, audit + profiler logs |

There is no micro and no small for DocumentDB. The module rejects the RDS
burstable range with a plan-time precondition. If a dev environment cannot carry
USD 60/month, set `mode = "shared"`.

## Outputs

The seven uniform contract names, plus `reader_endpoint`, `arn`, `kms_key_arn`,
`master_username`, `tls_enabled`, the four cross-stack context outputs, and
`helm_values` (keyed by component).
