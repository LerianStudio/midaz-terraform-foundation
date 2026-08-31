# products/shared-resources/postgres

The **shared PostgreSQL tier**: one RDS instance per environment, owned by
`product = "shared"`, consumed by any number of products.

| | |
| --- | --- |
| Module | [`_modules/postgres-rds`](../../../_modules/postgres-rds) |
| Creates | `shared-{env}-postgres` |
| Secret | `shared-{env}-postgres/password` |
| A consumer resolves it with | `data "aws_db_instance"` on `shared-{env}-postgres` |
| State key | `aws/products/shared-resources/postgres/terraform.tfstate` |
| dev cost | `db.t4g.micro`, 20 GB — **~USD 15/month** |

**Optional.** Applying this directory is what enables the shared PostgreSQL
tier; there is no `postgres_enabled` toggle. Read
[`../README.md`](../README.md) for the trade-offs of opting in — noisy
neighbour, shared blast radius, one upgrade for everyone.

---

## `mode` is pinned to `dedicated`, and that is not a bug

This stack **creates**. `var.mode` on a datastore module answers *"does this
module CREATE the resource, or merely RESOLVE one that already exists?"* — it
does **not** answer *"is this resource shared?"*. There is no `mode` variable in
this root at all; the module call is pinned. The full explanation, including
why a `mode = "shared"` here would apply cleanly to an empty state, is in the
header of [`main.tf`](main.tf) and in [`../README.md`](../README.md).

`product` is pinned to `"shared"` by validation, because `shared-{env}-postgres`
and `shared-{env}-postgres/password` **are** the discovery contract.

---

## How a product consumes it

```hcl
# examples/aws/products/<product>/postgres/envs/dev.tfvars
mode = "shared"
```

That is the whole change. The product's root creates nothing, resolves
`shared-{env}-postgres` by name, and reads
`shared-{env}-postgres/password` from Secrets Manager. Its `security_group_id`
output comes back `null` — **opening this instance is this stack's job**, which
is what the ingress section below is about.

RDS creates exactly **one** initial database (`database_name`, default
`lerian`). Each consuming product is expected to use its own schema or its own
logical database, created outside Terraform.

---

## Ingress

Two sources, both on by default:

| Source | Variable | Default | Depends on |
| --- | --- | --- | --- |
| `Type=private` subnet CIDRs | `allow_private_subnet_cidr_ingress` | `true` | `infra-base/vpc` |
| EKS node security group | `eks_node_security_group_lookup_enabled` | `true` | `infra-base/eks` |
| Anything else | `allowed_security_group_ids`, `allowed_cidr_blocks` | `[]` | — |

The EKS lookup uses `data "aws_security_groups"` — the **plural** data source,
which returns an empty list instead of failing — so this stack is appliable
before the cluster exists. `check "eks_node_security_group_resolved"` (inside
`_modules/product-network`) warns while it resolves nothing; it must **not**
still be warning in steady state.

`envs/prd.tfvars-example` ships `allow_private_subnet_cidr_ingress = false`:
security-group-only ingress, the destination posture, which needs
`infra-base/eks` applied first.

---

## Init and apply

```bash
cd examples/aws/products/shared-resources/postgres

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/shared-resources/postgres/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # *.tfvars is gitignored
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

`../../../` lands on `examples/aws`, where both `backend/` and `_modules/` live
— **three** levels up, not four. Switching environments in the same checkout
needs `-reconfigure`; the state key stays the same, segregation comes from the
bucket.

---

## Outputs

The seven uniform contract names — `mode`, `endpoint`, `port`,
`security_group_id`, `secret_arn`, `secret_name`, `identifier` — plus
`database_name`, `username`, `replica_endpoint`, `replica_identifier`,
`subnet_group_name`, `helm_values`, and the four context outputs (`vpc_name`,
`eks_cluster_name`, `ingress_security_group_ids`, `ingress_cidr_blocks`).

`endpoint` is the **raw AWS hostname**. There is no `dns_name` output and no
private zone: RDS presents a certificate for `*.{region}.rds.amazonaws.com`, so
a CNAME in front of it breaks TLS hostname verification.

`helm_values` carries the **midaz chart** variable names (`DB_ONBOARDING_*`,
`DB_TRANSACTION_*`). Other products' charts must not be assumed to match — see
the header of [`outputs.tf`](outputs.tf).

---

## Sizing traps the module catches at plan time

- **Performance Insights on `db.t4g.micro`** — AWS does not offer it on
  t2/t3/t4g micro and small. `performance_insights_enabled` must be `false` on
  the dev sizing.
- **`engine_version` stays MAJOR-only (`"16"`)** — pinning a full minor is a
  maintenance trap. AWS retired 16.3 and every apply that pinned it started
  failing with `Cannot find version 16.3 for postgres`.

---

## Validation

```bash
terraform fmt -check -recursive .
terraform init -backend=false -input=false
terraform validate
```

`terraform plan` needs AWS credentials and a configured backend: the ingress
lookups and the module's own VPC/subnet lookups hit the AWS API.
