# products/flowker/documentdb

DocumentDB for flowker. Root stack over
[`_modules/mongodb-documentdb`](../../../_modules/mongodb-documentdb).

> **The Helm handoff here is EMPTY, and that is deliberate.** flowker has no
> readable chart in this monorepo — `infrastructure/K8S/helm/charts/flowker/`
> contains two vendored tarballs and no `Chart.yaml`. Read
> [`../README.md`](../README.md) first: it explains what is inferred, what is
> verified, and what to ask the service owner.

One root, one datastore, one state file. Its sibling
[`../valkey`](../valkey) is independent.

| | |
|---|---|
| Module | `../../../_modules/mongodb-documentdb` |
| State key | `aws/products/flowker/documentdb/terraform.tfstate` |
| Creates | `flowker-{env}-docdb` (DocumentDB cluster) |
| Secret | `flowker-{env}-docdb/password` |
| Chart target | **unknown** — `helm_values` is `{}` |

## Run it

```bash
cd examples/aws/products/flowker/documentdb

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/flowker/documentdb/terraform.tfstate"

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
3. Nothing else. Step 3 in every sibling root is "translate to the chart", and
   there is no chart to translate to.

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

`db.t3.medium` is the floor — roughly USD 60/month for one instance. Since this
product cannot be wired to a chart yet, `mode = "shared"` is the sensible posture
meanwhile: it costs nothing and still proves the network path.

## The empty `helm_values`

`outputs.tf` emits `helm_values = {}`. The header of that file carries the full
reasoning; the short version:

- both vendored tarballs were extracted and read;
- the only literal env vars in them are the Bitnami `MONGODB_*` family, which
  configures the MongoDB **pod** and is meaningless against DocumentDB;
- searching for `MONGO_` (single word) returns zero matches;
- the three charts read alongside flowker use three *different* Mongo spellings,
  so there is no convention to fall back on.

Use the ordinary outputs instead:

```bash
terraform output endpoint port master_username secret_name
```

When flowker's chart lands in this monorepo, fill `helm_values` in from **its**
`values.yaml` — never from a sibling's.

## TLS

`documentdb_tls` stays `"disabled"`. Everywhere else in this repository that
comes with a named blocker (a CA bundle the chart has to mount); here the client
side cannot be assessed at all, because there is no chart to read. Raise it with
the service owner rather than flipping it and finding out in production.

The host side is already correct: `endpoint` is the raw
`*.docdb.amazonaws.com` name the DocumentDB certificate covers, so hostname
validation would pass.

## Outputs

Seven uniform contract names — `mode`, `endpoint`, `port`, `security_group_id`,
`secret_arn`, `secret_name`, `identifier` — plus `reader_endpoint`, `arn`,
`kms_key_arn`, `master_username`, `tls_enabled`, the cross-stack context
(`vpc_name`, `eks_cluster_name`, `ingress_*`), and the empty `helm_values`.

All of them are correct: the missing chart affects the *handoff*, not the
infrastructure.

No password is ever an output.

## Shared mode

`mode = "shared"` creates nothing and plans to zero resources. The module
resolves `shared-{env}-docdb` with `data "aws_rds_cluster"` — the AWS provider
ships no `data "aws_docdb_cluster"` at all — and the secret
`shared-{env}-docdb/password`. `security_group_id` comes back `null`.

`master_username` is still *declared* rather than read, so keep it equal to the
shared tier's (both default to `docdbadmin`).

Every sizing variable in the tfvars is ignored in that mode.
