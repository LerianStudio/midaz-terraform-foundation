# rabbitmq-amazonmq

Amazon MQ for RabbitMQ broker for a Lerian product. Migrated from the pre-v2
`examples/aws/amazonmq` stack, removed in v2.

## The two "modes" - read this first

This module carries two independent settings that both read like "mode". They are
unrelated, and conflating them is how you accidentally destroy a broker.

| Variable | Values | Meaning |
|---|---|---|
| `mode` | `dedicated`, `shared` | **Lerian sharing contract.** Whether this product gets its own broker or reuses the shared one from `products/shared-resources/rabbitmq`. Identical across every Lerian datastore module. |
| `broker_deployment_mode` | `SINGLE_INSTANCE`, `CLUSTER_MULTI_AZ` | **AmazonMQ topology.** How many nodes AWS runs and across how many AZs. |

The pre-v2 stack called the second one `deployment_mode` and derived
`local.name = "${var.name}-${local.mode_suffix}"` from it, where `mode_suffix` was
`single` / `cluster`. Reading that code, `mode` looked like it meant the sharing
contract. It never did. The variable was therefore renamed to
`broker_deployment_mode`, and the internal locals to `is_cluster_deployment` /
`broker_deployment_suffix`.

The `-single` / `-cluster` suffix is **kept on the broker name only**, because
`docs/UPGRADE-GUIDE.md` depends on it: a single-to-cluster migration runs both
brokers side by side, which requires two distinct broker names. It is controlled by
`append_deployment_suffix` (default `true`).

The suffix is **not** applied to the secret or the security group. Those stay on
the plain `{product}-{env}-rabbitmq`, which is what makes the shared **secret**
resolvable without knowing the shared broker's topology. The shared **broker**
is the one thing that does have to know it — see `shared_broker_name` under
**Modes**.

## What it creates (`mode = "dedicated"`)

| Resource | Name |
|---|---|
| `aws_mq_broker` | `{product}-{env}-rabbitmq-{single\|cluster}` |
| `aws_security_group` + ingress rules | `{product}-{env}-rabbitmq-sg` |
| `aws_secretsmanager_secret` | `{product}-{env}-rabbitmq/password` |

Preserved from the pre-v2 stack: both topologies, the one-subnet-per-AZ spreading
(`subnets_by_az` grouping, capped at the RabbitMQ maximum of 3), and all four
`lifecycle precondition` blocks, which catch AWS constraints at plan time instead
of ten minutes into an apply:

1. `ACTIVE_STANDBY_MULTI_AZ` rejected (ActiveMQ only).
2. `host_instance_type` outside the `mq.m5.*` / `mq.m7g.*` families rejected —
   in **both** topologies, since those are the only families AmazonMQ offers the
   RabbitMQ engine. This supersedes the pre-v2 check, which only rejected
   `mq.t3.*` under `CLUSTER_MULTI_AZ` and therefore let a `SINGLE_INSTANCE`
   `mq.t3.micro` plan cleanly and fail `CreateBroker` on apply.
3. `CLUSTER_MULTI_AZ` requires subnets in >= 2 distinct AZs.
4. At least one subnet must be found.

## Fixes applied during the migration

| Legacy | Now | Why |
|---|---|---|
| `var.deployment_mode` | `var.broker_deployment_mode` | Collided semantically with the contract's `mode`. See above. |
| secret `"${local.name}/amazonmq-password"` (carried the `-single`/`-cluster` suffix) | `"${module.naming.name}/password"` | Uniform path across datastore modules, and suffix-free so shared mode can resolve it. |
| No DNS record at all | still no DNS record | An intermediate revision of this module added a `rabbitmq.{product}` CNAME in a private zone, on the argument that the broker id is part of the AWS hostname. It was reverted: the broker certificate covers `*.mq.{region}.on.aws`, AmazonMQ exposes no plaintext listener, so an alias in front of the broker fails hostname verification on the AMQPS handshake — and Helm values are generated from `terraform output` on every deploy, so there was no hardcoded host being protected. The pre-v2 stack was right to have none. |
| `var.name` free-form | `product` + `environment` | Naming contract. |
| `environment` with `default = "<environment>"` | required, validated `dev\|stg\|prd` | The placeholder default applied literally when unset. |
| SG name from the suffixed `local.name` | `{product}-{env}-rabbitmq-sg` | Stable across a topology change. |
| Ingress with `ip_protocol = "-1"` | `tcp` on `5671` (AMQPS), plus `443` when `enable_console_ingress` | `-1` is **every protocol on every port**. The other four datastore modules scope by port; this one now does too. AmazonMQ for RabbitMQ listens on exactly those two ports. |
| `allow_vpc_cidr_ingress` widened unconditionally | fallback only, see **Ingress** below | A caller who passed a restricted allow list still got the whole VPC CIDR, public subnets included, and believed they had restricted the broker. |

Behaviour deliberately preserved: no egress rule is declared (the pre-v2 stack
did not declare one either), the management console stays reachable from the same
ingress sources (`enable_console_ingress` defaults to `true`, which is what the
`-1` rules allowed implicitly), and `apply_immediately` plus the general log
export default to `true`.

## AmazonMQ endpoints carry a scheme

AmazonMQ does not return a bare host. It returns
`amqps://b-1234abcd-....mq.us-east-2.on.aws:5671`. The module parses that string
— in both modes, through the same code path — and exposes each piece:

| Output | Value | Use it when |
|---|---|---|
| `endpoint` | `b-1234....mq.us-east-2.on.aws` | Helm `RABBITMQ_HOST`. Raw AWS host, no scheme, no port. |
| `port` | `5671` | Helm `RABBITMQ_PORT`. |
| `amqp_endpoint` | `amqps://b-1234....mq.us-east-2.on.aws:5671` | You want the URI exactly as AWS reports it. |

**Every component talking to AmazonMQ must set `RABBITMQ_URI: "amqps"` in its Helm
values** (see the repository README) - AmazonMQ exposes no plaintext AMQP
listener, only AMQPS on 5671.

**TLS is why there is no alias.** The broker certificate covers
`*.mq.<region>.on.aws` and the client always speaks AMQPS, so any name outside
that wildcard fails hostname verification. That is why `endpoint` is the raw AWS
host in both modes, why there is no `dns_name` output, and why no private zone
exists anywhere in this repository.

## Modes

- **`dedicated`** (default) - creates everything above.
- **`shared`** - creates nothing. Resolves the broker owned by
  `products/shared-resources/rabbitmq` (same module, `product = "shared"`), **by name**:
  - `endpoint`, `port`, `amqp_endpoint`, `endpoints`, `console_url`,
    `identifier`, `arn`, `broker_deployment_mode` and `is_cluster_mode` via
    `data "aws_mq_broker"` on `shared_broker_name`;
  - secret via `data "aws_secretsmanager_secret"` on
    `shared-{env}-rabbitmq/password` (override with `shared_secret_name`);
  - `security_group_id` is `null` — opening the shared broker is the
    shared-resources/rabbitmq ingress' job.

`console_url` is not null in shared mode; whether it is *reachable* still
depends on the ingress shared-resources/rabbitmq declared.

Note the two prefixes in `infra-base`: the foundation keeps `lerian-`
(`lerian-{env}-vpc`, `lerian-{env}-eks`), while the shared datastore tier uses
`shared-`. The `shared-` prefix only exists where a `dedicated` counterpart also
exists; the VPC and the cluster have none.

### `shared_broker_name`: the topology suffix has to be declared

RabbitMQ is the one datastore where the shared name is not simply
`shared-{env}-rabbitmq`. `append_deployment_suffix` is `true` on both sides, so
the shared broker is `shared-{env}-rabbitmq-single` **or**
`shared-{env}-rabbitmq-cluster` depending on the topology shared-resources/rabbitmq
deployed.

`data "aws_mq_broker"` matches the name **exactly**, and the AWS provider ships
no list/filter data source for MQ — so the suffix cannot be discovered, it has
to be declared:

| Variable | Default | Notes |
|---|---|---|
| `shared_broker_name` | `""` → derives `shared-{env}-rabbitmq-single` | Matches the shared-resources/rabbitmq **dev** tfvars (`SINGLE_INSTANCE`). |

`stg` and `prd` ship `CLUSTER_MULTI_AZ`, so a shared consumer there must pass
`shared_broker_name = "shared-{env}-rabbitmq-cluster"`. Getting it wrong is
loud, not silent: the plan fails naming the broker it searched for. The secret
is unaffected either way — it never carries the suffix.

## Inputs

### Contract

| Name | Type | Default | Description |
|---|---|---|---|
| `product` | string | - | Product owning the broker. `shared` for shared-resources/rabbitmq. |
| `environment` | string | - | `dev`, `stg` or `prd`. Validated. |
| `mode` | string | `"dedicated"` | `dedicated` or `shared`. Validated. Not the broker topology. |
| `extra_tags` | map(string) | `{}` | Merged on top of the standard Lerian tags. |
| `vpc_name` | string | `""` | `tag:Name` of the VPC. Empty derives `lerian-{env}-vpc`. |
| `subnet_tag_type` | string | `"database"` | `tag:Type` used to pick subnets. The pre-v2 stack used `private`. |

### Shared mode

| Name | Type | Default | Description |
|---|---|---|---|
| `shared_broker_name` | string | `""` | Broker name resolved in shared mode. Empty derives `shared-{env}-rabbitmq-single`. The topology suffix cannot be discovered — see above. |
| `shared_secret_name` | string | `""` | Secret name resolved in shared mode. Empty derives `shared-{env}-rabbitmq/password`. |

### Ingress

**One rule, worded identically in all five Lerian datastore modules.**

- **Any** entry in `allowed_cidr_blocks` **or** `allowed_security_group_ids` →
  exactly those sources are allowed and **nothing else**. The VPC CIDR is never
  added on top. A caller who restricts, restricts.
- **Both** lists empty → fall back to the VPC CIDR when
  `allow_vpc_cidr_ingress` is `true` (the behaviour the pre-v2
  `examples/aws/amazonmq` stack had, kept so a migrated stack does not silently
  lose connectivity), or to
  **no ingress rule at all** when it is `false`.
- Rules are always scoped to a port, never to a whole protocol.
- `check "ingress_is_reachable"` warns at plan time whenever the resolved set
  comes out empty, so an unreachable broker is never silent.

| Name | Type | Default | Description |
|---|---|---|---|
| `allowed_security_group_ids` | `list(string)` | `[]` | Security group IDs allowed on the broker ports. Non-empty disables the VPC CIDR fallback. |
| `allowed_cidr_blocks` | `list(string)` | `[]` | CIDR blocks allowed on the broker ports. Non-empty disables the VPC CIDR fallback. |
| `allow_vpc_cidr_ingress` | `bool` | `true` | **Fallback only.** VPC CIDR, applied only when both lists above are empty. |
| `port` | `number` | `5671` | AMQPS. The only AMQP listener AmazonMQ exposes for RabbitMQ - there is no plaintext `5672`, which is why `RABBITMQ_URI` must be `amqps`. |
| `console_port` | `number` | `443` | RabbitMQ management console and management HTTP API, served over HTTPS. |
| `enable_console_ingress` | `bool` | `true` | Also open `console_port` to the resolved sources. `false` narrows the broker to AMQPS only. |

Every resolved source gets one rule per port in the `ingress_ports` output —
`[5671]` or `[5671, 443]`.

> Both of these are behaviour changes. Ingress used to be written with
> `ip_protocol = "-1"`, which allowed **every protocol on every port** from each
> source, and `allow_vpc_cidr_ingress` used to widen to the whole VPC CIDR even on
> top of a restricted allow list.

### Broker engine and sizing

| Name | Type | Default | Description |
|---|---|---|---|
| `broker_deployment_mode` | string | `"CLUSTER_MULTI_AZ"` | `SINGLE_INSTANCE` or `CLUSTER_MULTI_AZ`. Validated. AmazonMQ topology. |
| `append_deployment_suffix` | bool | `true` | Append `-single` / `-cluster` to the broker name. |
| `engine_type` | string | `"RabbitMQ"` | The preconditions assume RabbitMQ. |
| `engine_version` | string | `"3.13"` | Broker engine version. |
| `host_instance_type` | string | `"mq.m5.large"` | RabbitMQ accepts only `mq.m5.*` / `mq.m7g.*`, in both modes. Smallest is `mq.m7g.medium`. Precondition-enforced. |
| `publicly_accessible` | bool | `false` | Public access to the broker. |
| `auto_minor_version_upgrade` | bool | `true` | Automatic minor upgrades. |
| `apply_immediately` | bool | `true` | Skip the maintenance window. |
| `enable_general_logs` | bool | `true` | Export the general log to CloudWatch. |
| `mq_admin_user` | string (sensitive) | `"rabbitmqadmin"` | Administrator username. |

## Outputs

| Name | Description |
|---|---|
| `mode` | `var.mode`, echoed. |
| `endpoint` | Raw AWS broker host, no scheme, no port — `RABBITMQ_HOST`. Populated in **both** modes. |
| `port` | AMQPS port, `5671`, parsed from the endpoint AWS reports in both modes. |
| `security_group_id` | Broker SG. `null` in shared mode. |
| `secret_arn` | ARN of the password secret. |
| `secret_name` | Name of the password secret. |
| `identifier` | Broker id (`b-xxxxxxxx`). In shared mode, the id of the resolved shared broker. |
| `amqp_endpoint` | Full `amqps://host:5671` URI, in both modes. |
| `console_url` | RabbitMQ management console URL, in both modes. Reachability depends on the `enable_console_ingress` rules of whoever owns the broker. |
| `endpoints` | Every endpoint AWS reports, in both modes. No stable primary in cluster topology. |
| `ingress_ports` | Ports the security group actually opens: `[5671]`, or `[5671, 443]` with `enable_console_ingress`. |
| `broker_name` | Broker name as it exists in AWS, suffix included. In shared mode, the exact string the lookup used. |
| `broker_deployment_mode` | Topology. Read from the resolved broker in shared mode. |
| `is_cluster_mode` | `true` when `CLUSTER_MULTI_AZ`. Derived from the resolved broker in shared mode. |
| `arn` | Broker ARN. Resolved from the shared broker in shared mode. |
| `admin_username` | Administrator username (sensitive). Echoed from `mq_admin_user` — the MQ data source reports users as an unordered set, so in shared mode this is what the caller declared, not a read of the shared broker. |

The first seven are the uniform datastore contract and are identical across
`postgres-rds`, `mongodb-documentdb`, `valkey-elasticache`, `rabbitmq-amazonmq`
and `streaming-msk`.

## The generated password is URL-safe by construction

`random_password.master` draws from **alphanumerics plus `-` `_` `.` `~`** at
**32 characters**. That symbol set is the RFC 3986 §2.3 *unreserved* production
— the characters that carry no syntactic meaning anywhere in a URI and so never
need percent-encoding.

**This is deliberate and it is not a style choice. Do not widen it.**

There is no non-URL consumer of this password. The AMQP contract across this
fleet is a connection **string**, never a host/user/password triple:

| Consumer | How the password reaches it |
|---|---|
| `br-sfn` (`correios` rail) | `correios.secrets.RABBITMQ_URL` — `amqps://<user>:<password>@<endpoint>:5671/`, a URL by construction. The chart states the rule for its Postgres sibling in the same words: *"passwords must be URL-safe (no `@ : / ? # %`)"* |
| `plugin-br-pix-switch` | `RABBITMQ_URI` |
| `plugin-br-bank-transfer` | `amqp://bank_transfer:$(RABBITMQ_PASSWORD)@…` (`templates/configmap.yaml:168`), assembled through Kubernetes `$(VAR)` expansion — escaping is structurally impossible on that path |

The previous set was `!#$%^&*()-_+{}<>?`. Three of its members break a URL, each
differently: `#` truncates at the fragment so the vhost is silently dropped, `%`
opens an invalid percent-escape, `?` starts the query string. At 16 characters
over ~17 symbols, drawing at least one was the **likely** outcome — an
intermittent connection failure that reproduces on roughly every other rebuild
and points at nothing.

Entropy went **up**, not down: 32 characters over the 66-symbol alphabet is
~193 bits against the ~101 bits the old 16-character password carried.

### Engine limits this was checked against

AmazonMQ carries the **strictest** rule of the four datastore modules — the only
one with an enforced complexity requirement.

| Constraint | AmazonMQ RabbitMQ `User.password` | This module |
|---|---|---|
| Length | ≥ 12, no documented maximum | 32 |
| Forbidden | `,` `:` `=` | none emitted |
| Complexity | **"must contain at least 4 unique characters"** — a hard API rule | satisfied *deterministically*: `min_lower`/`min_upper`/`min_numeric`/`min_special` = 2 each guarantees one distinct character from each of four classes, whatever the draw |

That last row is why the `min_*` floors in this module are load-bearing rather
than decorative. Removing them makes the constraint merely probable.

> Adjacent, so it does not get rediscovered: the AmazonMQ RabbitMQ **username**
> must not contain a tilde. Only the password is generated here, so nothing in
> this module trips that — but do not paste this character set into a username
> generator.

> **Sibling modules differ on purpose.** `postgres-rds` and `mongodb-documentdb`
> use the same `-_.~`. `valkey-elasticache` uses **`-` alone**, because the
> ElastiCache AUTH token is governed by an *allowlist* (`! & # $ ^ < > -`)
> rather than a blocklist, and `-` is its only member that is also RFC 3986
> unreserved. See that module's README.

### Changing this rotates the password

`length`, `override_special` and the `min_*` floors are all inputs to
`random_password`, so editing any of them **regenerates the value**. It flows
into the broker user (`main.tf:373`), so the next `apply` rotates the admin
credential.

Plan for it rather than discovering it: the new value lands in
`{product}-{env}-rabbitmq/password`, and any workload holding the old one keeps
failing authentication until External Secrets resyncs the Kubernetes Secret and
the pods restart. Roll it in a maintenance window, dev first.

## Usage - dedicated

Dev, cheapest viable shape (single instance, `mq.m7g.medium` — the smallest type
the RabbitMQ engine offers):

```hcl
module "rabbitmq" {
  source = "../_modules/rabbitmq-amazonmq"

  product     = "midaz"
  environment = var.environment

  broker_deployment_mode = "SINGLE_INSTANCE"
  host_instance_type     = "mq.m7g.medium"
}
```

Production shape (3-node cluster):

```hcl
module "rabbitmq" {
  source = "../_modules/rabbitmq-amazonmq"

  product     = "midaz"
  environment = var.environment

  broker_deployment_mode = "CLUSTER_MULTI_AZ"
  host_instance_type     = "mq.m5.large"
}
```

Helm values wiring:

```yaml
RABBITMQ_HOST: <module.rabbitmq.endpoint>   # b-1234abcd-....mq.us-east-2.on.aws
RABBITMQ_PORT: "5671"
RABBITMQ_URI: "amqps"                       # mandatory for AmazonMQ
```

## Usage - shared

```hcl
module "rabbitmq" {
  source = "../_modules/rabbitmq-amazonmq"

  product     = "midaz"
  environment = var.environment
  mode        = "shared"

  # dev: the default already derives shared-dev-rabbitmq-single.
  # stg/prd run CLUSTER_MULTI_AZ, so declare the suffix there:
  # shared_broker_name = "shared-${var.environment}-rabbitmq-cluster"
}
```

Resolves the `shared-{env}-rabbitmq-{single|cluster}` broker and the
`shared-{env}-rabbitmq/password` secret. Requires `products/shared-resources/rabbitmq`
to have been applied with RabbitMQ enabled. `broker_deployment_mode` is ignored
in this mode - the shared broker's topology is whatever shared-resources/rabbitmq chose,
and it is reported back through the `broker_deployment_mode` output.

## Further reading

- `docs/UPGRADE-GUIDE.md` - single-instance to cluster migration. Destructive;
  read the warnings.
- `docs/CLUSTER-MODE-SUPPORT-TEST.md` - the real-AWS test report that validated
  the topology logic this module preserves.
