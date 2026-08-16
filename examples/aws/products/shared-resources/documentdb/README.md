# products/shared-resources/documentdb

The **shared MongoDB-compatible tier**: one DocumentDB cluster per environment,
owned by `product = "shared"`, consumed by any number of products.

| | |
| --- | --- |
| Module | [`_modules/mongodb-documentdb`](../../../_modules/mongodb-documentdb) |
| Creates | `shared-{env}-docdb` |
| Secret | `shared-{env}-docdb/password` |
| A consumer resolves it with | `data "aws_rds_cluster"` on `shared-{env}-docdb` |
| State key | `aws/products/shared-resources/documentdb/terraform.tfstate` |
| dev cost | `db.t3.medium` × 1 — **~USD 60/month** |

**Optional, and the first place cost bites.** `db.t3.medium` is the *smallest
class DocumentDB offers* — the RDS micro/small range does not exist for this
service — so one instance costs more than the shared PostgreSQL and Valkey tiers
combined. Applying this directory is what enables it; there is no
`documentdb_enabled` toggle. Read [`../README.md`](../README.md) for the
trade-offs.

---

## Two naming quirks, both intentional

**`docdb` in AWS, `MONGO_*` in the chart.** `docdb` is the AWS service;
`mongodb` is what the applications speak. The split lives only in the chart
variable names — no hostname carries either label. Do not "align" one of them.

**Resolved through `data "aws_rds_cluster"`, not a docdb data source.** The AWS
provider ships **no** `data "aws_docdb_cluster"` at all: the docdb service only
exposes `aws_docdb_engine_version` and `aws_docdb_orderable_db_instance`,
neither of which resolves an existing cluster. DocumentDB clusters are
first-class DB clusters in the RDS control plane (`aws rds describe-db-clusters`
lists them with `engine = "docdb"`). Validated in a real AWS account, not
inferred from the schema: the data source returns `engine = "docdb"`,
`endpoint`, `reader_endpoint`, `port` and `master_username`.

---

## `mode` is pinned to `dedicated`, and that is not a bug

This stack **creates**. `var.mode` answers *"does this module CREATE or
RESOLVE?"*, not *"is this shared?"*. There is no `mode` variable in this root.
See the header of [`main.tf`](main.tf).

`product` is pinned to `"shared"` by validation, because `shared-{env}-docdb`
and `shared-{env}-docdb/password` **are** the discovery contract.

---

## How a product consumes it

```hcl
# examples/aws/products/<product>/documentdb/envs/dev.tfvars
mode = "shared"
```

The product's root creates nothing, resolves `shared-{env}-docdb` by name, and
reads `shared-{env}-docdb/password`. Its `security_group_id` comes back `null`
— opening this cluster is this stack's job.

DocumentDB creates a database **lazily on first write**, so Terraform creates
none and each consuming product picks its own.

`master_username` is declared on both sides rather than read across, because the
module marks its copy `sensitive` and reading it back would redact the whole
`helm_values` map. Keep both at the default `docdbadmin`.

---

## Known gap: `documentdb_tls = "disabled"` everywhere

It ships `disabled` in all three tfvars examples, and the reason is **no longer
the hostname**. Consumers receive the raw `*.docdb.amazonaws.com` writer
endpoint, which is exactly what the DocumentDB certificate covers, so hostname
validation passes. (It used to be a genuine trap: this tier published a
`mongodb.lerian.{zone}` CNAME that no certificate covered. Removing the private
zone removed the trap.)

What is still missing is chart-side. Enabling TLS requires the consuming charts
to mount the global RDS CA bundle into `MONGO_*_TLS_CA_CERT`, which Terraform
does not distribute. On a **shared** cluster that switch is all-or-nothing:
flipping it here forces every consuming product to have the CA bundle wired on
the same day. Turn it on once they all do.

`MONGO_*_PARAMETERS` in `helm_values` carries `retryWrites=false`
unconditionally — DocumentDB does not implement retryable writes and every
driver enables them by default, so omitting it makes every write fail — and
appends `tls=true` when the parameter is enabled.

---

## Ingress

Two sources, both on by default:

| Source | Variable | Default | Depends on |
| --- | --- | --- | --- |
| `Type=private` subnet CIDRs | `allow_private_subnet_cidr_ingress` | `true` | `infra-base/vpc` |
| EKS node security group | `eks_node_security_group_lookup_enabled` | `true` | `infra-base/eks` |
| Anything else | `allowed_security_group_ids`, `allowed_cidr_blocks` | `[]` | — |

The EKS lookup is the **plural** data source, so this stack is appliable before
the cluster exists; `check "eks_node_security_group_resolved"` warns until it
resolves. `envs/prd.tfvars-example` ships security-group-only ingress.

---

## Init and apply

```bash
cd examples/aws/products/shared-resources/documentdb

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/shared-resources/documentdb/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

---

## Outputs

The seven uniform contract names, plus `reader_endpoint`, `arn`, `kms_key_arn`,
`master_username`, `tls_enabled`, `helm_values`, and the four context outputs.

`endpoint` is the raw AWS writer endpoint; `reader_endpoint` points back at the
writer while `instances_count` is 1.

`helm_values` carries the **midaz chart** variable names — see the header of
[`outputs.tf`](outputs.tf).

---

## Validation

```bash
terraform fmt -check -recursive .
terraform init -backend=false -input=false
terraform validate
```
