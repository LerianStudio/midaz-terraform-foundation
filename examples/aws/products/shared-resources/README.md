# products/shared-resources

The **shared** side of the hybrid datastore model: one PostgreSQL instance, one
DocumentDB cluster, one Valkey replication group, one AmazonMQ broker and one
MSK cluster per environment, owned by `product = "shared"` and consumed by any
number of products.

```
examples/aws/products/shared-resources/
├── postgres/     -> _modules/postgres-rds         shared-{env}-postgres
├── documentdb/   -> _modules/mongodb-documentdb   shared-{env}-docdb
├── valkey/       -> _modules/valkey-elasticache   shared-{env}-valkey
├── rabbitmq/     -> _modules/rabbitmq-amazonmq    shared-{env}-rabbitmq[-single|-cluster]
└── msk/          -> _modules/streaming-msk        shared-{env}-msk
```

> ## THIS WHOLE DIRECTORY IS OPTIONAL
>
> It is not part of `infra-base`. `infra-base` is what **every** deployment
> needs — the VPC and the EKS cluster. This tier is a choice: a client who wants
> per-product dedicated datastores never applies anything here and pays nothing
> for it.
>
> **A client who does opt in takes on the trade-offs below, knowingly.**

---

## What you are accepting by opting in

| Trade-off | What it means in practice |
| --- | --- |
| **Noisy neighbour** | One product's slow query, hot key, unacked queue or runaway topic degrades every other product on the same instance. There is no per-product resource quota at the AWS level. |
| **Shared blast radius** | One failover, one storage-full, one bad parameter change, one accidental `terraform destroy` takes **all** consuming products down together. Deletion protection is on in stg and prd for exactly this reason. |
| **One upgrade for everyone** | An engine version bump, a TLS enforcement switch, a topology change: every consumer is migrated on the same day or none is. Several settings in this tier are therefore all-or-nothing — see the table further down. |
| **Coordination the tooling cannot enforce** | Who owns which PostgreSQL schema, which Valkey logical database, which Kafka topic, which RabbitMQ vhost. Terraform creates none of those; they are conventions between teams. |
| **A shared credential** | Each datastore has ONE master user. Per-product users are created on the datastore itself, outside Terraform. |

And what you get: **the second, third and fourth product not each paying for
their own instance.** One product on a dedicated `db.t4g.micro` costs exactly
the same as one product on a shared one — the tier only pays off above one
consumer. That trade-off, not the price, is what should decide `mode` per
product per environment.

---

## Opt-in is per directory, not per toggle

This tier used to be **one root stack**, `infra-base/shared-services`, with five
`*_enabled` booleans and all five datastores in a single state file. It is now
five independent roots, one per service — the same shape as
`products/midaz/*`.

**The toggles are gone.** `postgres_enabled`, `documentdb_enabled`,
`valkey_enabled`, `rabbitmq_enabled` and `msk_enabled` no longer exist, and
neither do the `count` expressions they drove.

| Before | Now |
| --- | --- |
| `postgres_enabled = true` in one tfvars | `terraform apply` in `postgres/` |
| `msk_enabled = false` | never apply `msk/` |
| flipping a toggle off | `terraform destroy` in that directory |
| one state file, five datastores | five state files, one each |

The toggle became redundant the moment each service got its own directory:
enabling a datastore **is** applying its directory, and not applying it is what
"disabled" means. What that buys, beyond removing a redundant switch:

- **an MSK apply can never queue behind an RDS apply**, and a corrupt state
  takes down one datastore instead of five;
- a datastore you never apply produces no plan noise, no `count = 0` resources
  and no `one(module.x[*].y)` gymnastics in the outputs;
- `terraform destroy` scopes to one datastore, which on a shared tier is the
  difference between one outage and five.

State keys moved with the split:

| Before | Now |
| --- | --- |
| `aws/infra-base/shared-services/terraform.tfstate` | `aws/products/shared-resources/{postgres,documentdb,valkey,rabbitmq,msk}/terraform.tfstate` |

---

## Read this first: every module here runs with `mode = "dedicated"`

This is the most confusing part of the model and it is where someone is going to
"fix" a bug that is not one. So, plainly:

> `var.mode` on a datastore module answers **"does this module CREATE the
> resource, or does it merely RESOLVE one that already exists?"**
>
> It does **not** answer "is this resource shared?"

These five stacks are the real **owners** of the shared datastores. They create
the RDS instance, the DocumentDB cluster, the Valkey group, the broker, the MSK
cluster, their security groups, their Secrets Manager entries and their CMKs.
Creating requires `mode = "dedicated"`. **No other value creates anything.**

`"shared"` describes how a **product consumes** what this tier owns:

| Stack | `product` | `mode` | Effect |
| --- | --- | --- | --- |
| `products/shared-resources/*` (these) | `shared` | `dedicated` | **creates** the shared datastore |
| product root, shared datastore | `midaz` | `shared` | **creates nothing**; resolves the resource by name + the secret this tier published |
| product root, dedicated datastore | `midaz` | `dedicated` | creates its own `midaz-{env}-postgres`, separate from the shared one |

Setting `mode = "shared"` in one of these roots would create nothing and then
try to resolve a shared datastore that, by definition, nobody had created. The
apply would **succeed** and produce an empty, useless state — which is why
**`mode` is not a variable in these roots at all**. It is pinned in the module
call, with the reasoning in each `main.tf` header.

### The corollary: `product` must stay `shared`

Shared mode in the modules does **not** take the shared product as an input. It
derives the name it looks up from the `shared` label:

| Module | Data source | Name resolved | Secret resolved |
| --- | --- | --- | --- |
| `postgres-rds` | `aws_db_instance` | `shared-{env}-postgres` | `shared-{env}-postgres/password` |
| `mongodb-documentdb` | `aws_rds_cluster` | `shared-{env}-docdb` | `shared-{env}-docdb/password` |
| `valkey-elasticache` | `aws_elasticache_replication_group` | `shared-{env}-valkey` | `shared-{env}-valkey/auth-token` |
| `rabbitmq-amazonmq` | `aws_mq_broker` | `shared-{env}-rabbitmq-{single\|cluster}` | `shared-{env}-rabbitmq/password` |
| `streaming-msk` | `aws_msk_cluster` | `shared-{env}-msk` | `AmazonMSK_shared-{env}-msk` |

With `product = "shared"` these stacks produce exactly those strings, verified
against the module source. **Each of the five roots carries its own `validation`
pinning it** — previously there was one, in the single shared-services root. A
different value produces resources that no shared consumer can find, silently.
If you genuinely want a second shared tier, that is a product root stack with
`mode = "dedicated"`, not a second copy of this directory.

Each module still ships an escape hatch for a tier named outside this Terraform:
`shared_identifier` (postgres, docdb, valkey), `shared_broker_name` (rabbitmq)
and `shared_secret_name` (all five). Every one defaults to `""`, which derives
the names above.

### DocumentDB reads through `aws_rds_cluster`

The AWS provider ships **no** `data "aws_docdb_cluster"` — the docdb service
only exposes `aws_docdb_engine_version` and `aws_docdb_orderable_db_instance`,
neither of which resolves an existing cluster. DocumentDB clusters are
first-class DB clusters in the RDS control plane. Validated in a real AWS
account: the data source returns `engine = "docdb"`, `endpoint`,
`reader_endpoint`, `port` and `master_username`.

### RabbitMQ is the one a consumer has to declare

`data "aws_mq_broker"` matches the name **exactly** and the AWS provider ships
no list/filter data source for MQ, so the `-single` / `-cluster` topology suffix
cannot be discovered.

**`products/shared-resources/rabbitmq` is what decides it.** Its
`broker_deployment_mode` sets the broker name; the consumer's
`shared_broker_name` has to match:

| This tier's `rabbitmq/envs/*.tfvars-example` | Broker name | Consumer sets |
| --- | --- | --- |
| dev — `SINGLE_INSTANCE` | `shared-dev-rabbitmq-single` | `""` (derived default matches) |
| stg — `CLUSTER_MULTI_AZ` | `shared-stg-rabbitmq-cluster` | `"shared-stg-rabbitmq-cluster"` |
| prd — `CLUSTER_MULTI_AZ` | `shared-prd-rabbitmq-cluster` | `"shared-prd-rabbitmq-cluster"` |

The `products/midaz/rabbitmq/envs/*.tfvars-example` files carry the matching
values. Getting it wrong is loud, not silent: the plan fails naming the broker
it searched for. The secret never carries the suffix, so it resolves either way.
Confirm the exact string with `terraform output -raw broker_name` in
`rabbitmq/`.

---

## Two prefixes, on purpose

| Prefix | Stacks | Why |
| --- | --- | --- |
| `lerian-{env}-*` | `lerian-{env}-vpc`, `lerian-{env}-eks` (`infra-base`) | the **foundation**. Unconditionally shared, no dedicated counterpart exists, so a `shared` label would carry no information |
| `shared-{env}-*` | the five datastores created here | the shared **datastore tier**. Here the dedicated/shared choice does exist, and the label is exactly what separates `shared-dev-postgres` from `midaz-dev-postgres` at a glance |

**Do not "fix" this into a single prefix.** None of these five roots calls the
`naming` module: the VPC and the cluster names are derived inside
`_modules/product-network` from the `lerian` literals, because deriving them
from a prefix seeded with `product = "shared"` would look for
`shared-{env}-vpc`, which does not exist.

Also not renamed, because they are not resource names: `database_name =
"lerian"` (a database), `scram_username = "lerian"` (a Kafka user) and the
`Repository` tag.

The DocumentDB suffix is `docdb` while the chart variables say `MONGO_*`.
Intentional — `docdb` is the AWS service, `mongodb` is what the applications
speak. Do not align one of them.

---

## No private DNS, and why

This tier used to publish a `{component}.lerian.{zone}` CNAME per datastore into
a `{env}.lerian.internal` private zone owned by an `infra-base/route53` stack.
**All of it is gone** — the zone, the records, the stack, the `dns_zone_name` /
`create_dns_record` / `dns_record_ttl` variables and every `*_dns_name` output.

Every AWS datastore presents a certificate for its **own** service domain — RDS
`*.{region}.rds.amazonaws.com`, DocumentDB `*.docdb.amazonaws.com`, AmazonMQ
`*.mq.{region}.on.aws`, ElastiCache `*.{cluster}.{region}.cache.amazonaws.com`.
A private CNAME in front of any of them breaks TLS hostname verification on
every client that checks it. The counter-argument — "a stable name protects
consumers from an endpoint change" — does not hold: Helm values are generated
from `terraform output` on every deploy, so there is no hardcoded host to
protect.

Every endpoint this tier hands out is the **raw AWS hostname**, and consumers
find it by **name through a data source**, not by DNS.

---

## Ingress: the part the shared model lives or dies on

A product running with `mode = "shared"` gets **`security_group_id = null`**
from its module. It creates no security group, so it **cannot authorise
itself**. Opening the shared datastores is exclusively this tier's job, and a
shared datastore nobody can reach is the failure mode of the whole design.

Each root computes its own allow list from the same two sources — the logic
lives once, in [`_modules/product-network`](../../_modules/product-network),
which every root calls identically:

| Source | Variable | Default | Depends on |
| --- | --- | --- | --- |
| `Type=private` subnet CIDRs | `allow_private_subnet_cidr_ingress` | `true` | `infra-base/vpc` only |
| EKS node security group | `eks_node_security_group_lookup_enabled` | `true` | `infra-base/eks` |
| Anything else | `allowed_security_group_ids`, `allowed_cidr_blocks` | `[]` | — |

### Why the EKS lookup is the plural data source

`data "aws_eks_cluster"` is the obvious approach and it is the wrong one:
it is **singular**, so it **fails the plan** when the cluster does not exist,
which would make these stacks un-appliable before `infra-base/eks`.

`_modules/product-network` uses the **plural** one instead:

```hcl
data "aws_security_groups" "eks_nodes" {
  filter { name = "vpc-id", values = [data.aws_vpc.selected[0].id] }
  tags   = { Name = "${local.eks_cluster_name}-node" }
}
```

`aws_security_groups` returns an **empty list** rather than failing, so the plan
succeeds before the cluster exists and starts producing ingress rules on the
first apply after it does. `check "eks_node_security_group_resolved"` — which
lives in the module, so the message is written once rather than five times —
turns that transition into a visible warning rather than a silent gap. It must
**not** still be warning in steady state.

The match is on `tag:Name`, not `group-name`, because
`terraform-aws-modules/eks` creates that security group with `name_prefix`: the
real group name carries a generated suffix, while the tag is verbatim
`{cluster}-node`.

Accepting the ids by variable is kept as `allowed_security_group_ids`, but it
cannot be the default — nothing can put a generated security group id into a
committed `tfvars-example`.

### Why the private subnet CIDRs are the default

Both sources above are empty on the very first apply. `allow_private_subnet_cidr_ingress`
defaults to `true` because the CIDRs of the `Type=private` subnets depend only
on `infra-base/vpc`, so the shared tier is reachable from the first apply with
no manual step. It is also **tighter than the modules' own fallback**: the
private subnets hold the EKS nodes and the interface VPC endpoints, while the
whole-VPC CIDR additionally covers the public subnets, which have no business
reaching a datastore.

All five modules implement one identical ingress rule:

- any entry in `allowed_cidr_blocks` **or** `allowed_security_group_ids` →
  exactly those sources, nothing on top;
- both lists empty → the VPC CIDR when `allow_vpc_cidr_ingress` is `true`, or no
  ingress rule at all when it is `false`;
- each module carries `check "ingress_is_reachable"`, which warns when the
  resolved set is empty.

Every root here passes `allow_vpc_cidr_ingress = false`, so that if the allow
lists ever *do* come out empty the check fails loudly instead of quietly
widening to a CIDR that includes the public subnets.

`envs/prd.tfvars-example` sets `allow_private_subnet_cidr_ingress = false` in
all five: security-group-only ingress, the destination posture. It requires the
cluster to exist first — see the deploy order.

---

## Deploy order

```
bootstrap
  -> infra-base/vpc
  -> infra-base/eks
  -> [ products/shared-resources/* ]     <- only if you opted in
  -> products/<product>/*
```

Destroy is the reverse.

`infra-base/vpc` is a **hard prerequisite**: every root resolves the VPC and the
`Type=database` subnets by tag, and that lookup fails the plan when the target
does not exist.

`infra-base/eks` is **not** a hard prerequisite, but it should come first
anyway. Nothing in EKS depends on a datastore — its only cross-stack lookups are
the VPC and the `Type=private` subnets — while this tier wants the node security
group. Applying this tier first still works, but it **costs a second apply**:
the first produces CIDR-only ingress and the stack has to be re-applied after
`eks` to pick the group up. In the documented order instead the node security
group resolves on the first plan, `allow_private_subnet_cidr_ingress = false`
is viable from day one, and the `eks_node_security_group_resolved` warning never
appears.

The five roots have **no dependency on each other** — separate state files,
separate locks, separate blast radius. Run them in parallel.

A product root only depends on this tier when it sets `mode = "shared"`: that
root resolves the shared datastore by name and fails the plan if it is not there
yet. A fully `dedicated` deployment can skip this directory entirely.

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
— **three** levels up, not four, the same depth as `products/midaz/*`.

The other four, same shape:

| Stack | State key |
| --- | --- |
| `postgres` | `aws/products/shared-resources/postgres/terraform.tfstate` |
| `documentdb` | `aws/products/shared-resources/documentdb/terraform.tfstate` |
| `valkey` | `aws/products/shared-resources/valkey/terraform.tfstate` |
| `rabbitmq` | `aws/products/shared-resources/rabbitmq/terraform.tfstate` |
| `msk` | `aws/products/shared-resources/msk/terraform.tfstate` |

Switching environments in the same checkout requires `-reconfigure`. The state
key **stays the same** — segregation comes from the bucket, one per environment,
created by `examples/aws/bootstrap`. `backend.tf` is deliberately empty and
`../../../backend/{env}.hcl` is generated by bootstrap and gitignored.

---

## How a product consumes the tier

Nothing is read with `terraform_remote_state`. A product resolves the shared
tier by **resource name** and by **Secrets Manager name**, which is what
`mode = "shared"` does inside each module. A product that shares PostgreSQL and
Valkey but wants its own DocumentDB sets, in three separate root stacks:

```hcl
# products/midaz/postgres/envs/dev.tfvars
mode = "shared"       # resolves shared-dev-postgres + shared-dev-postgres/password

# products/midaz/valkey/envs/dev.tfvars
mode = "shared"       # resolves shared-dev-valkey + shared-dev-valkey/auth-token

# products/midaz/documentdb/envs/dev.tfvars
mode = "dedicated"    # creates midaz-dev-docdb, its own cluster
```

The outputs a product reads are the **same seven names in both modes**, which is
the whole point of the uniform contract:

| Output | Shared mode returns | Dedicated mode returns |
| --- | --- | --- |
| `endpoint` | the raw AWS hostname of the **shared** resource | the product's own |
| `identifier` | `shared-{env}-postgres` — the name that was resolved | `midaz-{env}-postgres` |
| `secret_name` | `shared-{env}-postgres/password` | `midaz-{env}-postgres/password` |
| `security_group_id` | `null` — **ingress is this tier's job** | the product's own group |
| `port` | read from the resolved resource | the port |

`endpoint` is never `null` in either mode, and neither is `identifier`: the
lookup is by that exact name, so echoing it back is what lets a caller assert
**which** instance was resolved.

Each of these five roots also exports a `helm_values` map. **It carries the
midaz chart's variable names**, verified against chart 8.7.0 — the *facts*
(host, port, user) are tier-level and identical for every consumer, but the
names are not Lerian-wide. `REDIS_HOST` carrying `"host:port"` and the inverted
`RABBITMQ_PORT_*` pair are midaz-chart conventions. A product on a different
chart maps `endpoint`, `port` and the username itself.

---

## Outputs, and what the split did to them

Every root exports the **seven uniform contract names** — `mode`, `endpoint`,
`port`, `security_group_id`, `secret_arn`, `secret_name`, `identifier` — plus
its datastore-specific ones, a `helm_values` map, and four context outputs
(`vpc_name`, `eks_cluster_name`, `ingress_security_group_ids`,
`ingress_cidr_blocks`) that let you assert the derived cross-stack strings and
verify the EKS lookup resolved, without reading a plan.

The old single root prefixed everything with the datastore name. The mapping is
mechanical:

| Old, in `infra-base/shared-services` | Now |
| --- | --- |
| `postgres_endpoint`, `postgres_port`, `postgres_secret_arn`, `postgres_secret_name`, `postgres_security_group_id`, `postgres_identifier`, `postgres_replica_endpoint` | the unprefixed name in `postgres/` |
| `documentdb_endpoint`, `documentdb_reader_endpoint`, `documentdb_port`, `documentdb_secret_arn`, `documentdb_secret_name`, `documentdb_security_group_id`, `documentdb_identifier` | the unprefixed name in `documentdb/` |
| `valkey_endpoint`, `valkey_reader_endpoint`, `valkey_port`, `valkey_secret_arn`, `valkey_secret_name`, `valkey_security_group_id`, `valkey_identifier` | the unprefixed name in `valkey/` |
| `valkey_auth_token_enforced` | `auth_token_enabled` in `valkey/` |
| `rabbitmq_endpoint`, `rabbitmq_amqp_endpoint`, `rabbitmq_port`, `rabbitmq_secret_arn`, `rabbitmq_secret_name`, `rabbitmq_security_group_id`, `rabbitmq_identifier`, `rabbitmq_broker_name`, `rabbitmq_console_url` | the unprefixed name in `rabbitmq/` |
| `msk_endpoint`, `msk_bootstrap_brokers_sasl_scram`, `msk_bootstrap_brokers_tls`, `msk_port`, `msk_secret_arn`, `msk_secret_name`, `msk_security_group_id`, `msk_identifier`, `msk_cluster_arn` | the unprefixed name in `msk/` |
| `vpc_name`, `eks_cluster_name`, `ingress_security_group_ids`, `ingress_cidr_blocks` | the same four names, in **each** of the five roots |

Each root also gained outputs the aggregated version never had, because they
were only reachable per-datastore: `database_name` / `username` /
`replica_identifier` / `subnet_group_name` (postgres), `arn` / `kms_key_arn` /
`master_username` / `tls_enabled` (documentdb), `engine_version_actual` /
`transit_encryption_enabled` / `subnet_group_name` (valkey),
`broker_deployment_mode` / `is_cluster_mode` / `endpoints` / `arn` /
`ingress_ports` / `admin_username` (rabbitmq), `bootstrap_brokers` /
`zookeeper_connect_string` / `cluster_uuid` / `configuration_arn` /
`kms_key_arn` / `scram_kms_key_arn` / `log_group_arn` (msk) — plus `helm_values`
on all five.

### Two outputs deliberately did not survive

**`{ds}_enabled` (five of them).** They echoed the toggles, and the toggles are
gone. Whether a datastore exists is now "was this directory applied", which
`terraform output` in that directory answers by succeeding or by reporting no
state at all.

**`shared_datastores`, the aggregate map.** It existed so a deployment script could
iterate five `count`-gated modules living in **one** state file. There are five state files now, so no single `terraform output` can
produce it. The equivalent is a loop over the directories:

```bash
cd examples/aws/products/shared-resources
for d in postgres documentdb valkey rabbitmq msk; do
  [ -d "$d/.terraform" ] || continue        # not applied = not enabled
  printf '%s	%s:%s
' "$d"     "$(terraform -chdir=$d output -raw endpoint 2>/dev/null)"     "$(terraform -chdir=$d output -raw port     2>/dev/null)"
done
```

The uniform seven names are what make that loop possible without special-casing
— the same property the aggregate map was built on.

---

## All-or-nothing settings

On a shared datastore several switches cannot be flipped per consumer. Each one
is documented at its variable; collected here because they are the settings most
likely to be changed without realising who else is affected:

| Setting | Root | Ships as | Flipping it |
| --- | --- | --- | --- |
| `documentdb_tls` | `documentdb/` | `"disabled"` in dev, stg **and prd** | requires **every** consuming chart to mount the global RDS CA bundle into `MONGO_*_TLS_CA_CERT` on the same day. Not a hostname problem any more — the raw endpoint is what the certificate covers. |
| `auth_token_enabled` | `valkey/` | `false` everywhere | locks out every consumer that has no Valkey AUTH client configuration, at the same instant. The token exists in Secrets Manager regardless. |
| `transit_encryption_mode` | `valkey/` | `"preferred"` everywhere | `"required"` rejects every plaintext consumer at once. |
| `broker_deployment_mode` | `rabbitmq/` | `SINGLE_INSTANCE` in dev, `CLUSTER_MULTI_AZ` in stg/prd | renames the broker, so every shared consumer's plan fails until it updates `shared_broker_name`. Loud, not silent — and the suffix is what makes a side-by-side migration possible. |
| `auto_create_topics_enable` | `msk/` | `false` | true lets two products silently collide on a topic name. |
| engine version bumps | all | — | one maintenance window for everyone. |

---

## Approximate cost

**Order-of-magnitude estimates only** — `us-east-1` on-demand list prices, 730
hours, storage at the example sizes, no data transfer, no reserved capacity, no
savings plan.

**Selecting instance types is the client's responsibility.** See the Instance
Types Disclaimer in the repository README: *Lerian Studio is not responsible for
performance issues, costs, or other impacts resulting from instance type
selections.* Price these against your own AWS Pricing Calculator.

| Root | dev (`dev.tfvars-example`) | prd (`prd.tfvars-example`) |
| --- | --- | --- |
| `postgres/` | `db.t4g.micro`, single-AZ, 20 GB — **~USD 15/mo** | `db.m7g.large` Multi-AZ + `db.m7g.large` replica, 100 GB — **~USD 450/mo** |
| `valkey/` | `cache.t4g.micro` × 1 — **~USD 12/mo** | `cache.m7g.large` × 3 Multi-AZ — **~USD 350/mo** |
| `documentdb/` | `db.t3.medium` × 1 — **~USD 60/mo** | `db.r6g.large` × 3 — **~USD 650/mo** |
| `rabbitmq/` | `mq.m7g.medium` SINGLE — **~USD 100/mo** | `mq.m5.large` CLUSTER_MULTI_AZ — **~USD 660/mo** |
| `msk/` | `kafka.t3.small` × 3 — **~USD 105/mo** | `kafka.m7g.large` × 3, 500 GB each — **~USD 630/mo** |
| **all five** | **~USD 290/mo** | **~USD 2,700/mo** |

The old single-root tfvars enabled only `postgres` and `valkey` in dev — about
USD 30/month — and left the other three off. **The equivalent now is applying
only `postgres/` and `valkey/`**, which is the recommended dev posture and why
the split makes the cost decision more legible rather than less: each directory
is a line item you either apply or do not.

Where the money is, and why there is no cheaper corner:

- **DocumentDB.** `db.t3.medium` is the *smallest class the service offers* —
  there is no micro. The module rejects the RDS micro/small sizes with a
  plan-time precondition rather than five minutes into the apply.
- **MSK.** `kafka.t3.small` is the floor, the service minimum is two brokers,
  and the broker count must be a **multiple of the number of client subnets**.
  With the three `Type=database` subnets `infra-base/vpc` creates, **three
  brokers is the minimum** unless `msk/`'s `subnet_ids` is narrowed to exactly
  two — which cannot be written into a committed example, because the ids are
  generated. On top of that, streaming is off by default in the charts.
- **RabbitMQ.** AmazonMQ offers the RabbitMQ engine only the `mq.m5.*` and
  `mq.m7g.*` families; **`mq.m7g.medium` is the smallest, at roughly USD
  100/month**. The burstable `mq.t2.*` / `mq.t3.*` types are **ActiveMQ-only**
  and AWS rejects them for RabbitMQ in **every** deployment mode,
  `SINGLE_INSTANCE` included — a module precondition asserts this at plan time.
  Every valid type clusters, so `CLUSTER_MULTI_AZ` does not force a bigger
  instance; it triples the node count. `mq.m5.large` in prd is a capacity
  decision on top of that.
- **PostgreSQL: Performance Insights is not available on `db.t4g.micro`.** AWS
  excludes t2/t3/t4g micro and small. The module rejects the combination at plan
  time.

---

## Validation

In each of the five directories:

```bash
terraform fmt -check -recursive .
terraform init -backend=false -input=false
terraform validate
```

`terraform plan` is not runnable without AWS credentials and a configured
backend: the ingress lookups and every module's own VPC/subnet lookup hit the
AWS API.
