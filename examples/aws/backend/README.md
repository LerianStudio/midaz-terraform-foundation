# Backend configuration

Generated Terraform backend settings, one file per environment.

`dev.hcl`, `stg.hcl` and `prd.hcl` are **not committed** — they are produced by
[`../bootstrap`](../bootstrap) when you apply it for an environment, and they
carry the client's AWS account id in the bucket name. `.gitignore` excludes
`examples/aws/backend/*.hcl`; this `README.md` and `.gitkeep` are the only
tracked files in the directory.

## Content

Each file is a partial backend configuration:

```hcl
bucket         = "lerian-tfstate-dev-123456789012"
region         = "us-east-1"
dynamodb_table = "lerian-tfstate-lock-dev"
encrypt        = true
```

Note what is **absent**: `key`. The bucket is already per-environment, so the
state key must not repeat the environment — it identifies the *stack* only, and
is passed on the command line.

## Usage

Every stack in this repository declares an empty `terraform { backend "s3" {} }`
and receives its configuration in two pieces at init time:

```bash
cd examples/aws/infra-base/vpc
terraform init \
  -backend-config=../../backend/dev.hcl \
  -backend-config="key=aws/infra-base/vpc/terraform.tfstate"
```

From a product service stack one directory deeper, the relative path is
`../../../backend/`:

```bash
cd examples/aws/products/midaz/postgres
terraform init \
  -backend-config=../../../backend/dev.hcl \
  -backend-config="key=aws/products/midaz/postgres/terraform.tfstate"
```

## Switching environments in the same working directory

Terraform caches the resolved backend in `.terraform/`. Pointing an
already-initialised directory at another environment requires `-reconfigure`,
otherwise Terraform offers to *copy* the dev state into the stg bucket:

```bash
terraform init -reconfigure \
  -backend-config=../../backend/stg.hcl \
  -backend-config="key=aws/infra-base/vpc/terraform.tfstate"
```

Use `-reconfigure` (discard the old backend, keep remote state where it is), not
`-migrate-state` (copy state across backends), unless copying is what you
actually want.

## Missing file

If `dev.hcl` does not exist, the bootstrap stack has not been applied for that
environment on this checkout. Run it:

```bash
cd examples/aws/bootstrap
terraform workspace select dev || terraform workspace new dev
terraform apply -var-file=envs/dev.tfvars
```

If the bucket already exists but the file does not (fresh clone, another
operator ran the bootstrap), write the file by hand from the four values above —
the bucket name is `lerian-tfstate-<env>-<account_id>`.
