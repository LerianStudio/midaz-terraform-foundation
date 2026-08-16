# products/plugin-br-pix-jd

AWS datastores for **plugin-br-pix-jd** — the Pix integration over the JD
partner interface.

```
examples/aws/products/plugin-br-pix-jd/
└── postgres/     -> _modules/postgres-rds         plugin-br-pix-jd-{env}-postgres
```

One datastore, one root, one state file. See
[`../midaz/README.md`](../midaz/README.md) for everything identical across
products: the `lerian-` / `shared-` prefix split, `module.network`, the absence
of private DNS, and why `endpoint` is always the raw AWS host.

---

## ⚠ Composition inferred — the chart is not in this repository

**Read this before using this stack for anything beyond a dev sandbox.**

`infrastructure/K8S/helm/charts/plugin-br-pix-jd/` contains **no `Chart.yaml`,
no `values.yaml` and no `templates/`**. It holds one `charts/` directory with
two vendored tarballs:

```
plugin-br-pix-jd/
└── charts/
    ├── postgresql-16.3.5.tgz          Bitnami postgresql, appVersion 17.2.0
    └── lerian-common-helm-1.3.4.tgz   Lerian LIBRARY chart, type: library
```

Neither is the product's chart.

The second one is Lerian-authored, which makes it tempting — and it is a dead
end by design. Its own `Chart.yaml` declares `type: library` and its description
says it *"renders nothing on its own"*. Its `_datastore.tpl` helper takes the
real env var name as a **caller-supplied argument**; the helper's own doc
comment reads:

> `nativeKey (req) the product's real env key (e.g. DB_ONBOARDING_HOST)`

In other words, even the shared Lerian library deliberately refuses to know what
`plugin-br-pix-jd` calls its variables — the consuming chart passes them in, and
that consuming chart is not here. The `DB_ONBOARDING_HOST` / `DB_LEDGER_HOST` /
`DB_FEES_HOST` / `DB_CRM_HOST` examples in the library's docs belong to **other**
products (midaz, fees, CRM) and must not be copied here.

The library does emit a few fixed keys of its own — the
`MULTI_TENANT_REDIS_HOST/PORT/TLS/PASSWORD` set and `RATE_LIMIT_REDIS_TIMEOUT_MS`
— but those are the library's cross-cutting concerns, not evidence about this
product, and there is no vendored Valkey tarball to go with them.

### What the evidence does and does not license

| | |
|---|---|
| **Established** | The product depends on **PostgreSQL**. A `postgresql` dependency tarball is vendored. |
| **Established, by absence** | It needs **no cache, no document store, no broker**. There is no `valkey`, `mongodb` or `rabbitmq` tarball beside it — the same evidence read the other way, and the reason this product has a single service directory. This matches `product-infra-dependencies.yaml`. |
| **NOT established** | Every env var name the application reads. |
| **NOT established** | The database name. `database_name` defaults to `"pixjd"` here as an infrastructure choice, not because anything states it. |

### Consequence: `helm_values` is empty

`outputs.tf` exports `helm_values = {}` with the reasoning inline. Deliberate,
and the safer failure:

> A wrong env var name does not fail the plan, does not fail the Helm render,
> and does not fail the pod start. It produces a service quietly talking to the
> chart's in-cluster default while the RDS instance sits idle — surfacing in
> production, as data written to the wrong place.

Guessing is not cheap here even for Postgres. Among the four readable Lerian
charts, three different families are in production use:

| Chart | PostgreSQL variable family |
|---|---|
| midaz | `DB_ONBOARDING_*` / `DB_TRANSACTION_*`, no plain `DB_HOST` |
| tracer | `DB_HOST` / `DB_PORT` / `DB_NAME` / `DB_USER` |
| plugin-access-manager | the same short `DB_*` family, but on the `auth` component only |
| br-consignado-gw | `POSTGRES_HOST` / `POSTGRES_PORT` / `POSTGRES_USER` / `POSTGRES_NAME` |

`plugin-br-pix-jd` is a sibling of `plugin-br-pix-direct-jd`, which **does**
have a readable chart — that is the first place to look for a house style, but
a sibling's convention is a hypothesis, not a source. Read this product's own
chart.

### To close this

1. Obtain the plugin-br-pix-jd chart (its own repository, or a rendered
   release).
2. Read `values.yaml` and the template that renders its ConfigMap.
3. Fill `helm_values` in `outputs.tf`, replacing the `⚠` block with a
   `Verified against chart <name> <version>, <file:line>` note like the tracer
   and br-consignado-gw roots carry.
4. Confirm `database_name` with the owning team and update the tfvars.
5. Re-confirm that PostgreSQL really is the only datastore. A vendored-tarball
   set is a strong hint, not a declaration — if the chart turns out to read
   `REDIS_*` or `STREAMING_*`, add the matching root then.

Until then: **do not run this stack in production.** The infrastructure is
correct; the handoff is not verifiable.

## What IS verified

Everything that does not depend on the chart:

- naming, tagging and the anti-collision contract
  (`plugin-br-pix-jd-{env}-postgres`, `plugin-br-pix-jd-{env}-postgres/password`);
- VPC / subnet / EKS-node-security-group resolution through `module.network`;
- the ingress model, the `dedicated` / `shared` switch, the seven uniform
  outputs;
- sizing per environment, copied from `products/midaz` without invention;
- `terraform validate`, `tflint` and `trivy config` clean.

## Helm handoff (what to map by hand)

```bash
cd examples/aws/products/plugin-br-pix-jd/postgres
terraform output -raw endpoint
terraform output -raw port
terraform output -raw database_name
terraform output -raw username
terraform output -raw secret_name
```

No password is ever an output. `secret_name` is what an External Secrets
Operator `ExternalSecret` references.

## Deploy order

```
1. examples/aws/bootstrap
2. examples/aws/infra-base/vpc            -> lerian-{env}-vpc
3. examples/aws/infra-base/eks            -> lerian-{env}-eks
4. examples/aws/products/shared-resources/*   (OPTIONAL, only for mode = "shared")
5. products/plugin-br-pix-jd/postgres
6. helm upgrade --install plugin-br-pix-jd ...   <- blocked on the chart being available
```

Step 2 is the one hard prerequisite. Step 3 is not — the EKS node security group
lookup is plural and returns empty rather than failing, and
`check "eks_node_security_group_resolved"` warns until the cluster exists.

## Running the stack

```bash
cd examples/aws/products/plugin-br-pix-jd/postgres

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/plugin-br-pix-jd/postgres/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

State key: `aws/products/plugin-br-pix-jd/postgres/terraform.tfstate`.

`*.tfvars` is gitignored; `*.tfvars-example` is not. Copy, then edit.

## What gets created

`mode = "dedicated"`, `environment = "dev"`:

| Stack | AWS resource | Secrets Manager | ~USD/month |
|---|---|---|---|
| postgres | `plugin-br-pix-jd-dev-postgres` (RDS `db.t4g.micro`, 20 GB) | `plugin-br-pix-jd-dev-postgres/password` | 15 |

Cheapest product in this batch — one datastore. Estimate; price it against your
own AWS Pricing Calculator.
