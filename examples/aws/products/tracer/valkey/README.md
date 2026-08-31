# products/tracer/valkey

**OPT-IN.** The multi-tenant connection-pool registry of tracer. Root stack over
[`_modules/valkey-elasticache`](../../../_modules/valkey-elasticache).

One root, one datastore, one state file. See [`../README.md`](../README.md) for
the product-level picture.

| | |
|---|---|
| Module | `../../../_modules/valkey-elasticache` |
| State key | `aws/products/tracer/valkey/terraform.tfstate` |
| Creates | `tracer-{env}-valkey` (ElastiCache replication group) |
| Secret | `tracer-{env}-valkey/auth-token` |
| Chart target | `tracer.configmap` (`MULTI_TENANT_REDIS_*` only) |

## Do not apply this unless multi-tenancy is on

tracer does **not** need a cache on its main path. The only consumer is the
multi-tenant connection-pool registry, and the chart renders every
`MULTI_TENANT_REDIS_*` key inside a single conditional branch:

```
templates/configmap.yaml:58-77   # gated on MULTI_TENANT_ENABLED == "true"
```

With multi-tenancy off, this replication group has no consumer at all —
`~USD 12/month` in dev, considerably more in production, for an idle cache.

There is no `valkey_enabled` toggle, on purpose, and the rule is the same one
`products/shared-resources/*` follows: **applying the directory is what enables
it; not applying it is what "disabled" means.** A toggle would put an empty
state file and a `count = 0` between you and the same outcome.

`mode = "shared"` is the middle path: the registry gets a cache without tracer
paying for a dedicated one.

## Run it

```bash
cd examples/aws/products/tracer/valkey

terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/tracer/valkey/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

`../../../` is **three** levels up and lands on `examples/aws`. Verified with
`terraform init -backend=false`.

Prerequisites: `infra-base/vpc`. `infra-base/eks` is optional at apply time.

## Ingress

Identical to the sibling root, because it is literally the same code: resolved
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

The single most important line in this file.

| Chart | `*_REDIS_HOST` | `*_REDIS_PORT` |
|---|---|---|
| midaz | `"host:port"` in one string | **does not exist** — deleted in chart 3.0 |
| **tracer** | **bare hostname** | **exists**, its own key |

`templates/configmap.yaml:62-63` renders the two independently, and the
`values.yaml` comments at 245-248 document them as separate values.
Concatenating here produces a registry dialling a hostname with a colon in it.

There is **no plain `REDIS_HOST`, `REDIS_PORT`, `REDIS_TLS` or `REDIS_DB`** in
this chart, in any form. A grep for `REDIS` across the whole chart returns
`MULTI_TENANT_REDIS_*` and nothing else. Do not add the midaz keys — a key the
chart does not read is dead weight that looks like configuration.

## `MULTI_TENANT_REDIS_TLS` reports *required*, not *available*

`transit_encryption_enabled` is `true` in every environment, but
`transit_encryption_mode` is `"preferred"` — ElastiCache then accepts TLS and
plaintext clients alike. Reporting `"true"` in that state would tell the
registry to open a handshake it has no CA configuration for, so `helm_values`
only reports `"true"` when the mode is `"required"`.

Note the disagreement while it lasts: the **chart** defaults this key to
`"true"` (`values.yaml:251`). That default describes an expectation; the
Terraform value describes what the server enforces, and is the one to wire.

## The auth-token gap is smaller here than in midaz

`auth_token_enabled` is `false` in every environment, including production —
but unlike the midaz chart, tracer ships **both** client-side knobs:

- `MULTI_TENANT_REDIS_TLS` (`values.yaml:251`);
- `MULTI_TENANT_REDIS_PASSWORD`, an optional chart secret. The chart says so in
  as many words at `templates/secrets.yaml:6`:
  *"MULTI_TENANT_REDIS_PASSWORD is optional (Redis without auth is allowed)"*.

So closing the gap is a tfvars change plus a values change, with **no chart
change needed** — which is exactly what blocks midaz. It is left at the safe
default anyway because flipping `transit_encryption_mode` to `"required"` and
`auth_token_enabled` to `true` in one step, in production, against a client
whose TLS trust store has not been verified, is how a registry goes dark.
Rehearse in stg, then flip.

The token **is** generated and written to `tracer-{env}-valkey/auth-token`
regardless, so this is a tfvars change later, not a rebuild.

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
