# products/underwriter

AWS datastores for **underwriter** (the lending product, also referred to as
*lender*): products, origination, servicing, accounting, portfolio, audit.

```
examples/aws/products/underwriter/
├── postgres/     -> _modules/postgres-rds         underwriter-{env}-postgres
└── valkey/       -> _modules/valkey-elasticache   underwriter-{env}-valkey
```

See [`../midaz/README.md`](../midaz/README.md) for everything identical across
products: the `lerian-` / `shared-` prefix split, `module.network`, the absence
of private DNS, and why `endpoint` is always the raw AWS host.

---

## ⚠ Composition inferred — the chart is not in this repository

**Read this before using these stacks for anything beyond a dev sandbox.**

`infrastructure/K8S/helm/charts/underwriter/` contains **no `Chart.yaml`, no
`values.yaml` and no `templates/`**. It holds one `charts/` directory with two
vendored dependency tarballs and an empty `tmpcharts-*` leftover:

```
underwriter/
├── charts/
│   ├── postgresql-16.3.5.tgz     Bitnami postgresql, appVersion 17.2.0
│   └── valkey-2.4.7.tgz          Bitnami valkey,     appVersion 8.0.2
└── tmpcharts-66156/              (empty)
```

Both tarballs were unpacked and their `Chart.yaml` read: they are **upstream
Bitnami charts**, not the product's own packaged chart. `underwriter` has no
`lerian-common-helm` tarball either, so unlike `plugin-br-pix-jd` there is not
even a library chart to inspect.

### What that does and does not license

| | |
|---|---|
| **Established** | The product depends on **PostgreSQL** and **Valkey**. Nobody vendors a dependency chart by accident, and the pair matches what `product-infra-dependencies.yaml` recorded. |
| **Established** | It depends on **nothing else in this repo's catalogue**. No mongodb, rabbitmq, kafka or S3 tarball is vendored — the same evidence, read the other way. |
| **NOT established** | Every env var name the application reads. The tarballs are the charts that *stand a database pod up*; they say nothing about how the product *connects to one*. |
| **NOT established** | The database name. `database_name` defaults to `"underwriter"` here as an infrastructure choice, not because anything states it. |

### Consequence: `helm_values` is empty in both roots

Both `outputs.tf` files export `helm_values = {}` with the reasoning inline.
This is deliberate, and it is the safer failure:

> A wrong env var name does not fail the plan, does not fail the Helm render,
> and does not fail the pod start. It produces a service quietly talking to the
> chart's in-cluster default while the RDS instance sits idle — surfacing in
> production, as data written to the wrong place.

An incomplete-and-honest `helm_values` is useful. An invented one is a
production incident with a plausible-looking commit behind it.

### Why guessing Redis names is especially unsafe here

Among the four Lerian charts that *are* readable, the same variable name behaves
four different ways:

| Chart | shape |
|---|---|
| midaz | `REDIS_HOST` carries `"host:port"`; `REDIS_PORT` was deleted in chart 3.0 |
| br-consignado-gw | `REDIS_HOST` carries `"host:port"`; it is the only Redis key at all |
| plugin-access-manager | `REDIS_HOST` is a **bare** host and the template appends `REDIS_PORT` — passing `host:port` yields `host:port:port` |
| tracer | no plain `REDIS_*`; only `MULTI_TENANT_REDIS_HOST` (bare) plus `MULTI_TENANT_REDIS_PORT` |

There is no majority and no Lerian-wide convention. The postgres side is no
better: `DB_ONBOARDING_*`, `DB_HOST`, and `POSTGRES_HOST` are all in production
use across the four.

`products/underwriter/valkey` therefore publishes **both** candidate shapes as
first-class outputs — `endpoint` and `port` split, plus `redis_host_port`
joined — so that whoever reads the chart can wire the release without coming
back to Terraform.

### To close this

1. Obtain the underwriter chart (its own repository, or a rendered release).
2. Read `values.yaml` and the template that renders its ConfigMap.
3. For Redis, check specifically whether the port is a separate key, embedded in
   the host, or appended by the template.
4. Fill `helm_values` in both `outputs.tf`, replacing the `⚠` block with a
   `Verified against chart <name> <version>, <file:line>` note like the tracer
   and br-consignado-gw roots carry.
5. Confirm `database_name` with the owning team and update the tfvars.

Until then: **do not run these stacks in production.** The infrastructure is
correct; the handoff is not verifiable.

## What IS verified

Everything that does not depend on the chart:

- naming, tagging and the anti-collision contract (`underwriter-{env}-postgres`,
  `underwriter-{env}-valkey`, and the matching Secrets Manager paths);
- VPC / subnet / EKS-node-security-group resolution through `module.network`;
- the ingress model, the `dedicated` / `shared` switch, the seven uniform
  outputs;
- sizing per environment, copied from `products/midaz` without invention;
- `terraform validate`, `tflint` and `trivy config` clean.

## Helm handoff (what to map by hand)

Both roots publish everything a consumer needs as individual outputs:

```bash
cd examples/aws/products/underwriter/postgres
terraform output -raw endpoint
terraform output -raw port
terraform output -raw database_name
terraform output -raw username
terraform output -raw secret_name

cd ../valkey
terraform output -raw endpoint          # bare host
terraform output -raw port
terraform output -raw redis_host_port   # "host:port", for a chart that wants it joined
terraform output -raw secret_name
```

No password is ever an output. `secret_name` is what an External Secrets
Operator `ExternalSecret` references.

## Security posture

`auth_token_enabled = false` and `transit_encryption_mode = "preferred"` in all
three environments, **including production**, because the chart is not available
and neither the application's AUTH support nor its TLS trust store can be
verified. Flipping either switch blind is how a production cache goes dark.

The token *is* generated and stored at `underwriter-{env}-valkey/auth-token`
regardless, so enabling it later is a tfvars change, not a rebuild.

## Deploy order

```
1. examples/aws/bootstrap
2. examples/aws/infra-base/vpc            -> lerian-{env}-vpc
3. examples/aws/infra-base/eks            -> lerian-{env}-eks
4. examples/aws/products/shared-resources/*   (OPTIONAL, only for mode = "shared")
5. products/underwriter/{postgres,valkey}     <- in any order, in parallel
6. helm upgrade --install underwriter ...     <- blocked on the chart being available
```

## Running a stack

```bash
cd examples/aws/products/underwriter/postgres

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/underwriter/postgres/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

| Stack | State key |
|---|---|
| postgres | `aws/products/underwriter/postgres/terraform.tfstate` |
| valkey | `aws/products/underwriter/valkey/terraform.tfstate` |

## What gets created

`mode = "dedicated"`, `environment = "dev"`:

| Stack | AWS resource | Secrets Manager | ~USD/month |
|---|---|---|---|
| postgres | `underwriter-dev-postgres` (RDS `db.t4g.micro`, 20 GB) | `underwriter-dev-postgres/password` | 15 |
| valkey | `underwriter-dev-valkey` (ElastiCache `cache.t4g.micro`, 1 node) | `underwriter-dev-valkey/auth-token` | 12 |
| **total** | | | **~27** |

Estimates; price them against your own AWS Pricing Calculator.
