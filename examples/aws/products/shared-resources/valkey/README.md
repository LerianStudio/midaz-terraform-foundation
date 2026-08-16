# products/shared-resources/valkey

The **shared Valkey tier**: one ElastiCache replication group per environment,
owned by `product = "shared"`, consumed by any number of products.

| | |
| --- | --- |
| Module | [`_modules/valkey-elasticache`](../../../_modules/valkey-elasticache) |
| Creates | `shared-{env}-valkey` |
| Secret | `shared-{env}-valkey/auth-token` |
| A consumer resolves it with | `data "aws_elasticache_replication_group"` on `shared-{env}-valkey` |
| State key | `aws/products/shared-resources/valkey/terraform.tfstate` |
| dev cost | `cache.t4g.micro` × 1 — **~USD 12/month** |

**Optional.** Applying this directory is what enables the shared Valkey tier;
there is no `valkey_enabled` toggle. Read [`../README.md`](../README.md) for the
trade-offs of opting in.

---

## `mode` is pinned to `dedicated`, and that is not a bug

This stack **creates**. `var.mode` on a datastore module answers *"does this
module CREATE the resource, or merely RESOLVE one that already exists?"* — not
*"is this resource shared?"*. There is no `mode` variable in this root; the
module call is pinned. See the header of [`main.tf`](main.tf).

`product` is pinned to `"shared"` by validation, because `shared-{env}-valkey`
and `shared-{env}-valkey/auth-token` **are** the discovery contract.

---

## A shared cache is one keyspace

This is the isolation caveat specific to Valkey. ElastiCache exposes 16 logical
databases per node and **Terraform creates none of them**. Two products writing
the same key name into the same logical database clobber each other.

`redis_db_index` (emitted as `REDIS_DB`) is the crudest available separation,
and coordinating who uses which index — or which key prefix — is an application
concern this stack cannot enforce. It is one of the trade-offs of opting in.

---

## How a product consumes it

```hcl
# examples/aws/products/<product>/valkey/envs/dev.tfvars
mode = "shared"
```

The product's root creates nothing, resolves `shared-{env}-valkey` by name, and
reads `shared-{env}-valkey/auth-token` from Secrets Manager. Its
`security_group_id` comes back `null` — opening this group is this stack's job.

---

## Two known gaps, both all-or-nothing on a shared group

| Setting | Ships as | Why |
| --- | --- | --- |
| `auth_token_enabled` | `false` in dev, stg **and prd** | The token IS generated and stored in Secrets Manager regardless; this only decides whether ElastiCache **requires** it. The Lerian charts ship no Valkey AUTH client configuration yet, and on a shared group enabling it locks **every** consumer out at the same instant. |
| `transit_encryption_mode` | `"preferred"` everywhere | `preferred` accepts TLS and plaintext clients alike. `"required"` would reject every plaintext consumer at once — and `helm_values` reports `REDIS_TLS = "true"` only for `required`, precisely so a consumer is never told to negotiate TLS it has no CA configuration for. |

Neither is a naming problem any more: `endpoint` is the raw
`*.{cluster}.{region}.cache.amazonaws.com` host, which is exactly what the
ElastiCache certificate covers. The pre-v2 stack published a CNAME **and** ran
`transit_encryption_enabled = true` pointed at it — the exactly-broken
combination that removing the private zone fixed.

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
cd examples/aws/products/shared-resources/valkey

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/shared-resources/valkey/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

---

## Outputs

The seven uniform contract names, plus `reader_endpoint`,
`engine_version_actual`, `auth_token_enabled`, `transit_encryption_enabled`,
`subnet_group_name`, `helm_values`, and the four context outputs.

`auth_token_enabled` is what the pre-split stack called
`valkey_auth_token_enforced`.

`helm_values` carries the **midaz chart** variable names, and `REDIS_HOST` is a
single `"host:port"` string — the chart dropped `REDIS_PORT` in 3.0. That is a
midaz-chart convention, not a Lerian-wide one; see the header of
[`outputs.tf`](outputs.tf).

---

## Validation

```bash
terraform fmt -check -recursive .
terraform init -backend=false -input=false
terraform validate
```
