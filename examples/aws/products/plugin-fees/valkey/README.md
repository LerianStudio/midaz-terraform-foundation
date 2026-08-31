# products/plugin-fees/valkey

**OPT-IN.** The multi-tenant connection-pool registry of plugin-fees. Root stack
over [`_modules/valkey-elasticache`](../../../_modules/valkey-elasticache).

One root, one datastore, one state file. See [`../README.md`](../README.md) for
the product-level picture.

| | |
|---|---|
| Module | `../../../_modules/valkey-elasticache` |
| State key | `aws/products/plugin-fees/valkey/terraform.tfstate` |
| Creates | `plugin-fees-{env}-valkey` (ElastiCache replication group) |
| Secret | `plugin-fees-{env}-valkey/auth-token` |
| Chart target | **`fees.configmap`** (`MULTI_TENANT_REDIS_*` only) |

## Do not apply this unless multi-tenancy is on

plugin-fees does **not** need a cache on its main path. The only consumer is the
multi-tenant connection-pool registry, and the chart renders every
`MULTI_TENANT_REDIS_*` key inside a single conditional branch:

```
templates/fees/configmap.yaml:96-110   # gated on MULTI_TENANT_ENABLED == "true"
values.yaml:196                        # MULTI_TENANT_ENABLED defaults to "false"
```

With multi-tenancy off, this replication group has no consumer at all —
`~USD 12/month` in dev, considerably more in production, for an idle cache.

There is no `valkey_enabled` toggle, on purpose, and the rule is the same one
`products/shared-resources/*` follows: **applying the directory is what enables
it; not applying it is what "disabled" means.** A toggle would put an empty
state file and a `count = 0` between you and the same outcome.

`mode = "shared"` is the middle path: the registry gets a cache without
plugin-fees paying for a dedicated one.

## Why this directory exists

The chart discovery in `infrastructure/IAC/product-infra-dependencies.yaml`
recorded plugin-fees as `valkey: no`. That is accurate for the default
deployment and incomplete as a statement about the chart — which is exactly the
annotation `tracer` already carried (*"opcional, só multi-tenant"*).

`tracer` and `plugin-fees` are the same shape: Redis only on the multi-tenant
path, no subchart, host and port split. `tracer` got a `valkey/` root; this
product did not, and the asymmetry was an accident of two different batches
rather than a decision. This root closes it, and both entries in the discovery
YAML are now annotated the same way.

The predecessor of this file — [`../README.md`](../README.md), section *"One
correction to the discovery YAML"* — described exactly this directory as the
work still to do. It now describes the directory as shipped.

## Run it

```bash
cd examples/aws/products/plugin-fees/valkey

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/plugin-fees/valkey/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

`../../../` is **three** levels up and lands on `examples/aws`. Verified with
`terraform init -backend=false`.

Prerequisites: `infra-base/vpc`. `infra-base/eks` is optional at apply time.

## Ingress

Identical to the sibling roots, because it is literally the same code: resolved
by [`_modules/product-network`](../../../_modules/product-network), called as
`module.network` with `enabled = var.mode == "dedicated"`. `Type=private` subnet
CIDRs plus the EKS node security group, matched by
`tag:Name = "lerian-{env}-eks-node"` with the plural data source;
`check "eks_node_security_group_resolved"` lives in that module and warns while
the lookup is empty.

> `var.subnet_tag_type` (`"database"`) is the **placement** filter and goes to
> `valkey-elasticache` only. `product-network` keeps its own default
> (`"private"`), the **ingress** filter.

The "nothing can reach this cache" case is not re-asserted here — the module
carries `check "ingress_is_reachable"`.

## The host is BARE — this is the opposite of midaz

| Chart | `*_REDIS_HOST` | `*_REDIS_PORT` |
|---|---|---|
| midaz | `"host:port"` in one string | **does not exist** — deleted in chart 3.0 |
| **plugin-fees** | **bare hostname** | **exists**, its own key |
| tracer | bare hostname | exists, its own key |

`templates/fees/configmap.yaml:104-105` renders the two independently, and the
host goes through `quote` alone — no `printf`, no scheme, no `host:port` join
anywhere in the chart. Concatenating here produces a registry dialling a
hostname with a colon in it.

`MULTI_TENANT_REDIS_HOST` is wrapped in `required(...)`, so with multi-tenancy
on and the key empty the Helm render **fails** rather than producing a pod that
dials nothing. That is the desired behaviour and the reason `helm_values` exists.

There is **no plain `REDIS_HOST`, `REDIS_PORT`, `REDIS_TLS` or `REDIS_DB`** in
this chart, in any form. A grep for `REDIS` across the whole chart returns
`MULTI_TENANT_REDIS_*` and nothing else. Do not add the midaz keys — a key the
chart does not read is dead weight that looks like configuration.

## The values path is `fees.configmap`, not `tracer.configmap`

The single most important line in this file, because this root was adapted from
[`products/tracer/valkey`](../../tracer/valkey) and the two charts use
**identical variable names under different values prefixes**:

```
fees.configmap.MULTI_TENANT_REDIS_HOST      <- this product
tracer.configmap.MULTI_TENANT_REDIS_HOST    <- the other one
```

Merging the `helm_values` output into the wrong prefix produces a chart that
renders `required` failures while every value looks correct in
`terraform output`.

## `MULTI_TENANT_REDIS_TLS` reports *required*, not *available*

`transit_encryption_enabled` is `true` in every environment, but
`transit_encryption_mode` is `"preferred"` — ElastiCache then accepts TLS and
plaintext clients alike. Reporting `"true"` in that state would tell the
registry to open a handshake it has no CA configuration for, so `helm_values`
only reports `"true"` when the mode is `"required"`.

**The two charts in this family disagree on the default, and plugin-fees has the
less safe one:**

| Chart | `MULTI_TENANT_REDIS_TLS` default | |
|---|---|---|
| plugin-fees | `"false"` | `values.yaml:215` |
| tracer | `"true"` | `values.yaml:251` |

Neither default describes the server. The Terraform value does, and is the one
to wire — which also means this stack's output is what stops the plugin-fees
tenant cache connection from being plaintext by default. Worth raising at a
production review independently of this directory.

## The auth-token gap is a configuration change, not a chart change

`auth_token_enabled` is `false` in every environment, including production — but
plugin-fees ships **both** client-side knobs:

- `MULTI_TENANT_REDIS_TLS` (`values.yaml:215`);
- `MULTI_TENANT_REDIS_PASSWORD`, a **named** optional key in the chart Secret.
  Unlike tracer — which emits the whole `.Values.tracer.secrets` map through a
  generic `range` and ships the key commented out — plugin-fees templates it
  explicitly and guards it on the value being non-empty
  (`templates/fees/secrets.yaml:28-30`), with the key declared at
  `values.yaml:246`. An absent password is therefore a supported state, not an
  empty string in the Secret.

So closing the gap is a tfvars change plus a values change, with **no chart
change needed**. It is left at the safe default anyway because flipping
`transit_encryption_mode` to `"required"` and `auth_token_enabled` to `true` in
one step, in production, against a client whose TLS trust store has not been
verified, is how a registry goes dark. Rehearse in stg, then flip.

The token **is** generated and written to `plugin-fees-{env}-valkey/auth-token`
regardless, so this is a tfvars change later, not a rebuild.

> The auth token itself is generated from a **one-character** special set (`-`).
> That is not a weakness — see
> [`_modules/valkey-elasticache/README.md`](../../../_modules/valkey-elasticache/README.md),
> which explains why the ElastiCache allowlist and RFC 3986 intersect in exactly
> one character, and why 32 characters over 63 symbols is ~191 bits regardless.

## Availability

`multi_az_enabled` requires **both** `num_cache_clusters >= 2` **and**
`automatic_failover_enabled = true`. Setting one without the others fails the
apply, not the plan.

A single cache cluster (the dev sizing) also means `reader_endpoint` comes back
empty — there is no replica to read from. The chart has no reader variable
anyway.

## Outputs

Seven uniform contract names — `mode`, `endpoint`, `port`, `security_group_id`,
`secret_arn`, `secret_name`, `identifier` — plus `reader_endpoint`,
`engine_version_actual`, `auth_token_enabled`, `transit_encryption_enabled`,
`subnet_group_name`, the cross-stack context, and `helm_values`.

`endpoint` is the raw ElastiCache primary endpoint in both modes, and it is what
`MULTI_TENANT_REDIS_HOST` takes verbatim. There is no `dns_name`: with transit
encryption on, the certificate only covers
`*.{cluster}.{region}.cache.amazonaws.com`, so an alias in front of the primary
endpoint fails TLS hostname verification.

```bash
terraform output -json helm_values | jq
```

`MULTI_TENANT_REDIS_PASSWORD` is never an output — `secret_name` is what an
External Secrets Operator `ExternalSecret` references.

## Shared mode

`mode = "shared"` creates nothing and plans to zero resources. The module
resolves `shared-{env}-valkey` with
`data "aws_elasticache_replication_group"` and the secret
`shared-{env}-valkey/auth-token` with `data "aws_secretsmanager_secret"`, so
`endpoint`, `reader_endpoint` and `port` come from the resolved group.
`security_group_id` comes back `null`.

The name is fully derived, so this root exposes no variable for it. The module's
own `shared_identifier` is the escape hatch.

## No subchart to turn off

plugin-fees declares exactly one dependency — `mongodb` 16.4.0
(`Chart.yaml:29-33`, `condition: mongodb.enabled`). There is no Valkey or Redis
subchart and no `valkey:` / `redis:` block in `values.yaml`, so unlike the
DocumentDB sibling there is no `enabled: false` / `external: true` pair to set.
The cache is external by construction.
