# products/plugin-br-bank-transfer/documentdb

Audit and event persistence for the TED lifecycle. Root stack over
[`_modules/mongodb-documentdb`](../../../_modules/mongodb-documentdb).

One root, one datastore, one state file. See [`../README.md`](../README.md) for
the product-level picture.

| | |
|---|---|
| Module | `../../../_modules/mongodb-documentdb` |
| State key | `aws/products/plugin-br-bank-transfer/documentdb/terraform.tfstate` |
| Creates | `plugin-br-bank-transfer-{env}-docdb` (DocumentDB cluster) |
| Secret | `plugin-br-bank-transfer-{env}-docdb/password` |
| Chart target | `bankTransfer.secrets` (`MONGO_URI`) — **not** the ConfigMap |

The chart calls this datastore mandatory: *"MongoDB configuration (mandatory for
audit/event persistence)"*.

## Run it

```bash
cd examples/aws/products/plugin-br-bank-transfer/documentdb

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/plugin-br-bank-transfer/documentdb/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

## There is no `MONGO_HOST`

The plugin is URI-only. `templates/configmap.yaml` carries `MONGO_ENABLED`,
`MONGO_DATABASE` and three pool-tuning keys and **nothing that addresses a
server**. The single connection setting is `MONGO_URI`, and it lives in
`bankTransfer.secrets`.

That is why `helm_values` here is empty and the payload is in
`helm_secret_values`. The `mongo_uri` output exports the same string on its own
for templating or assertions.

## The URI keeps the password out of Terraform state

```
mongodb://docdbadmin:$(MONGO_PASSWORD)@<writer-endpoint>:27017/?authSource=admin&retryWrites=false
```

`$(MONGO_PASSWORD)` is **Kubernetes env expansion**, not Terraform
interpolation — Terraform only interpolates `${...}`, so `$(` is a literal here.

The mechanism is the chart's own, from `bank-transfer.mongoEnv` in
`templates/_helpers.tpl`: it emits a `MONGO_PASSWORD` env sourced with
`secretKeyRef`, then a `MONGO_URI` env with a plain `value:`, and the kubelet
expands `$(VAR)` in env values against earlier entries in the same list. The
chart states the intent out loud — *"the app is URI-only, so the URI is assembled
here rather than embedding a plaintext password in the Secret"*.

Set `bankTransfer.secrets.MONGO_PASSWORD` from `secret_name` through External
Secrets; that is what makes `mongoEnv` emit the `MONGO_PASSWORD` env the
expansion needs.

> This trick works **only** because `MONGO_URI` arrives as `env:`. Its RabbitMQ
> sibling in this same product delivers `RABBITMQ_URL` through `envFrom:`, where
> Kubernetes does not expand `$(VAR)` at all — see
> [`../rabbitmq/README.md`](../rabbitmq/README.md).

## `retryWrites=false` is mandatory

DocumentDB does not implement retryable writes, and every modern driver enables
them by default — omit the parameter and every write fails. The chart's own
bundled-Mongo URI does **not** carry it, which is correct against real MongoDB
and fatal against DocumentDB.

`authSource=admin` is correct for a DocumentDB master user: DocumentDB
authenticates the master against `admin`, not against the application database.
The chart's bundled URI uses `authSource=admin` too, so both paths agree.
`tls=true` is appended when `documentdb_tls = "enabled"`.

## The external path is a cliff, not a slope

Read `bank-transfer.mongoEnv` before wiring this:

| Situation | What the pod gets |
|---|---|
| bundled subchart | `MONGO_URI` built by the helper from the subchart Service |
| `mongodb.auth.existingSecret` set | same, password from that Secret |
| external **and** `bankTransfer.secrets.MONGO_URI` set | the operator's URI, verbatim |
| external **and no** `MONGO_URI` | **no `MONGO_URI` env at all** |

The last row renders cleanly. No `required()`, no error — the plugin simply
starts with no Mongo connection string. So on the managed-DocumentDB path,
setting `bankTransfer.secrets.MONGO_URI` from this root is mandatory.

Pair it with both subchart switches:

```yaml
mongodb:
  enabled:  false
  external: true
```

## `MONGO_DATABASE` is not emitted

DocumentDB creates a database lazily on first write, so Terraform never creates
it and must not claim to know it. The chart is internally inconsistent about the
name anyway: `MONGO_DATABASE` defaults to `plugin_br_bank_transfer` while the
bundled subchart provisions `plugin_br_bank_transfer_jd`. Neither is Terraform's
to pick.

## TLS is a documented gap

`documentdb_tls` stays `disabled` in all three environments, matching
`products/shared-resources/documentdb`. One thing has to land first: the chart
mounting the global RDS CA bundle into `bankTransfer.secrets.MONGO_TLS_CA_CERT`,
which Terraform cannot distribute.

The host side is already right — the URI always carries the raw
`*.docdb.amazonaws.com` writer endpoint, which is exactly what the DocumentDB
certificate covers, so hostname validation passes the moment the CA is
available. See `envs/prd.tfvars-example`.

## Sizing

| Env | Class | Instances | Notes |
|---|---|---|---|
| dev | `db.t3.medium` | 1 | ~USD 60/month — the SMALLEST class the service offers |
| stg | `db.t3.medium` | 2 | exercises failover and the reader endpoint |
| prd | `db.r6g.large` | 3 | one per AZ, deletion protection, audit + profiler logs |

There is no micro and no small for DocumentDB. The module rejects the RDS
burstable range with a plan-time precondition rather than five minutes into the
apply. If a dev environment cannot carry USD 60/month, set `mode = "shared"`.

## Outputs

The seven uniform contract names, plus `reader_endpoint`, `arn`, `kms_key_arn`,
`master_username`, `tls_enabled`, the four cross-stack context outputs,
`helm_values` (empty, on purpose), `helm_secret_values` and `mongo_uri`.
