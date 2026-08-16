# bootstrap — Terraform state backend, per environment

Creates the S3 bucket and DynamoDB lock table that every other stack in
`examples/aws/` uses as its remote backend, and writes the generated
`examples/aws/backend/<env>.hcl` those stacks consume.

Run this **first**, **once per environment**. It replaces the manual
`aws s3api create-bucket` / `aws dynamodb create-table` steps.

| Resource                                         | Purpose                                                     |
| ------------------------------------------------ | ----------------------------------------------------------- |
| `aws_s3_bucket.tfstate`                          | `lerian-tfstate-{env}-{account_id}` — holds state           |
| `aws_s3_bucket_versioning`                       | Every state write keeps its predecessor                     |
| `aws_s3_bucket_server_side_encryption_configuration` | AES256, or `aws:kms` when `kms_key_arn` is set          |
| `aws_s3_bucket_public_access_block`              | All four flags true                                         |
| `aws_s3_bucket_ownership_controls`               | `BucketOwnerEnforced` — ACLs disabled                       |
| `aws_s3_bucket_lifecycle_configuration`          | Expire noncurrent versions; abort stale multipart uploads    |
| `aws_s3_bucket_policy`                           | Deny any request where `aws:SecureTransport` is false        |
| `aws_dynamodb_table.tfstate_lock`                | `lerian-tfstate-lock-{env}` — PAY_PER_REQUEST, SSE, PITR    |
| `local_file.backend_config`                      | `examples/aws/backend/{env}.hcl`                            |

State is segregated **per environment**: dev, stg and prd each get their own
bucket and their own lock table, so a dev apply can never touch prd state even
when all three live in the same AWS account.

---

## This stack's own state is LOCAL

There is deliberately no `backend.tf`. This stack creates the backend, so it
cannot use it. Two acceptable end states:

1. **Recommended** — commit the state file into the client's **private**
   infrastructure repository.
2. Migrate it into the bucket it just created, once that bucket exists:

   ```bash
   terraform init -migrate-state \
     -backend-config=../backend/dev.hcl \
     -backend-config="key=aws/bootstrap/terraform.tfstate"
   ```

   Trade-off: after migrating, destroying the bucket destroys the state that
   describes the bucket. Recoverable via `terraform import`, but avoidable.

Losing this state does not lose the bucket or the table — it only means a
`terraform import` is needed before Terraform manages them again.

`.gitignore` already excludes `*.tfstate`, `*.tfstate.*` and
`terraform.tfstate.d/`, so nothing leaks by accident from this checkout.

---

## Multi-environment local state: use workspaces

**A single local state file cannot hold three environments.** Applying `stg` on
top of a state that already describes `dev` makes Terraform plan the dev bucket
and table as replacements, rewrites the state, and orphans dev's real resources
— they keep existing and keep costing money, but nothing manages them.

**Decision: local Terraform workspaces, one per environment.**

```bash
cd examples/aws/bootstrap
terraform init

# dev
terraform workspace new dev            # or: terraform workspace select dev
terraform apply -var-file=envs/dev.tfvars

# stg
terraform workspace new stg
terraform apply -var-file=envs/stg.tfvars

# prd
terraform workspace new prd
terraform apply -var-file=envs/prd.tfvars
```

Each workspace's state lands in
`terraform.tfstate.d/<workspace>/terraform.tfstate`.

### Why workspaces and not `-state=dev.tfstate`

Both work. Workspaces were chosen because the selection is **sticky** —
Terraform records it in `.terraform/environment` and every later command (`plan`,
`apply`, `output`, `destroy`, `state list`) honours it automatically.

A `-state=` flag must be repeated on **every** command, and the first time it is
omitted Terraform silently falls back to `terraform.tfstate` — reintroducing
exactly the collision this segregation prevents. A sticky default that is right
beats a flag that must be remembered.

Guard rail: `aws_s3_bucket.tfstate` carries a precondition asserting
`terraform.workspace == var.environment`. Running
`terraform apply -var-file=envs/prd.tfvars` inside the `dev` workspace fails at
plan time with an explicit message instead of clobbering dev. Workspace
`default` is exempt, so the `-state=` style remains available:

```bash
terraform apply -var-file=envs/dev.tfvars -state=dev.tfstate
terraform apply -var-file=envs/stg.tfvars -state=stg.tfstate
```

If you take that route, `-state=` must also be on `plan`, `output`, `show`,
`destroy` and every `state` subcommand.

Check where you are at any time:

```bash
terraform workspace show
terraform workspace list
```

---

## Usage

```bash
cd examples/aws/bootstrap
cp envs/dev.tfvars-example envs/dev.tfvars   # then edit region if needed

terraform init
terraform workspace new dev
terraform plan  -var-file=envs/dev.tfvars
terraform apply -var-file=envs/dev.tfvars
```

Output:

```text
bucket_name         = "lerian-tfstate-dev-123456789012"
dynamodb_table_name = "lerian-tfstate-lock-dev"
backend_config_path = "examples/aws/backend/dev.hcl"
init_command        = "terraform init -backend-config=../../backend/dev.hcl -backend-config=\"key=aws/infra-base/vpc/terraform.tfstate\""
```

`examples/aws/backend/dev.hcl` now exists and every other stack can be
initialised against it. The `key` is per-stack and does **not** repeat the
environment, because the bucket is already environment-scoped.

### Verifying the apply

```bash
aws s3api get-bucket-versioning --bucket lerian-tfstate-dev-<account_id>
# { "Status": "Enabled" }

aws s3api get-public-access-block --bucket lerian-tfstate-dev-<account_id>
# all four flags true

aws dynamodb describe-table --table-name lerian-tfstate-lock-dev \
  --query 'Table.[BillingModeSummary.BillingMode,SSEDescription.Status]'
```

### Variables

| Variable                                 | Default       | Notes                                                        |
| ---------------------------------------- | ------------- | ------------------------------------------------------------ |
| `environment`                            | — (required)  | `dev` \| `stg` \| `prd`                                      |
| `region`                                 | `us-east-1`   | Written verbatim into the generated `.hcl`                   |
| `kms_key_arn`                            | `""`          | Empty = SSE-S3 (AES256) + AWS managed DynamoDB key           |
| `noncurrent_version_expiration_days`     | `90`          | Minimum 7 — this is the state recovery window                |
| `abort_incomplete_multipart_upload_days` | `7`           | Cleans orphaned multipart parts                              |
| `write_backend_config`                   | `true`        | `false` to skip writing `../backend/{env}.hcl`               |

### Naming exception

Every other resource in this repository is `{product}-{env}-{component}` from the
`naming` module. The state bucket is not: S3 bucket names are globally unique
across all AWS accounts, so `lerian-dev-tfstate` would already be taken. The
bucket appends the account id — `lerian-tfstate-{env}-{account_id}` — resolved
from `data.aws_caller_identity.current`. The DynamoDB table is only
account+region scoped and needs no suffix. **Tags come from the naming module
unchanged** (`Product=lerian`, `Environment`, `ManagedBy=terraform`,
`Repository`, plus `Name`).

---

## Teardown — `prevent_destroy` is on, on purpose

Both the bucket and the lock table carry `prevent_destroy = true`, so
**`terraform destroy` on this stack fails**. That is the intended behaviour, not
a bug to work around casually: losing state means Terraform no longer knows what
it owns, and the next apply starts recreating live infrastructure.

`prevent_destroy` is hardcoded rather than driven by a variable because Terraform
does not evaluate expressions inside `lifecycle` blocks — there is no
`enable_deletion_protection = false` shortcut available at any price.

To tear down a validation environment, pick one:

### Option A — detach from Terraform, delete with the CLI (preferred)

No source edit, so nothing can be committed by mistake.

```bash
BUCKET=lerian-tfstate-dev-<account_id>

terraform state rm aws_s3_bucket.tfstate aws_dynamodb_table.tfstate_lock

# Versioning is on: rb fails until every version AND every delete marker is gone.
aws s3api delete-objects --bucket "$BUCKET" \
  --delete "$(aws s3api list-object-versions --bucket "$BUCKET" \
    --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}')"
aws s3api delete-objects --bucket "$BUCKET" \
  --delete "$(aws s3api list-object-versions --bucket "$BUCKET" \
    --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}')"
aws s3 rb "s3://$BUCKET"

aws dynamodb delete-table --table-name lerian-tfstate-lock-dev
```

`terraform state rm` also drops the dependent bucket sub-resources from state on
the next refresh; the S3 configuration resources have no existence of their own
once the bucket is gone.

### Option B — temporarily comment out the guard

```bash
# In main.tf, comment BOTH occurrences of `prevent_destroy = true`
terraform destroy -var-file=envs/dev.tfvars
# Then restore both lines immediately. Never commit them commented.
```

Option A is preferred precisely because Option B leaves a window where a stray
commit ships an unguarded state bucket.

> **Phase 1 validation note:** keep the `dev` bootstrap alive after validating.
> Tearing down the dev state bucket also destroys the state of every stack that
> was validated against it.

---

## Order of operations

```text
bootstrap (per env)  ->  examples/aws/backend/<env>.hcl
                              |
                              v
                     infra-base/vpc  ->  infra-base/eks
                              |
                              v
                     [ products/shared-resources/*  -  OPTIONAL, opt-in
                       per directory: postgres, documentdb, valkey,
                       rabbitmq, msk ]
                              |
                              v
                     product stacks (midaz, ...)
```
