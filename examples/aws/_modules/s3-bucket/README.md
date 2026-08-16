# s3-bucket

Object storage for Lerian products. In the Helm charts this role is filled by SeaweedFS; on AWS it
becomes S3.

One invocation creates **N buckets for one product**, each hardened the same way and each with its
own least-privilege IAM policy ready for IRSA.

| Product              | Logical bucket name        | Contents                      |
| -------------------- | -------------------------- | ----------------------------- |
| `reporter`           | `reporter-storage`         | Generated regulatory reports  |
| `fetcher`            | `external-data`            | Extracted source data         |
| `plugin-bc-correios` | `bc-correios-attachments`  | Correios attachments          |

## Pinned version

| Dependency                            | Version     | How it was checked                                     |
| ------------------------------------- | ----------- | ------------------------------------------------------ |
| `terraform-aws-modules/s3-bucket/aws` | `~> 5.15.4` | Terraform registry, latest stable at time of writing   |

> **Effective AWS provider floor.** `versions.tf` declares the repository-wide `aws >= 5.83.0`, but
> `s3-bucket` 5.15.4 itself requires `aws >= 6.42`. Terraform resolves the intersection, so
> `terraform init` here installs an AWS provider `>= 6.42`.

## Naming — the documented exception

Every other module produces `{product}-{environment}-{component}`. **S3 bucket names are globally
unique across all AWS accounts**, so a name built only from product and environment would collide
with any other AWS customer that picked the same words. The account id is therefore appended:

```
{product}-{environment}-{logical_name}-{account_id}
```

For example `reporter-dev-reporter-storage-123456789012`. The prefix still comes from the `naming`
module — only the account id suffix is added, resolved through
`data.aws_caller_identity.current`.

S3 caps names at 63 characters. That is enforced twice: a static `validation` rejects logical names
over 30 characters, and a `precondition` on the IAM policy checks the fully resolved name once the
account id is known. A failing precondition aborts the whole plan, so no bucket is created.

## Why this module has no `mode`

The uniform contract's `mode = "shared" | "dedicated"` exists because a Postgres or Valkey instance
is expensive enough that several products may want to share one. That reasoning does not transfer
to S3: a bucket costs nothing when empty, and its contents are the private data of exactly one
product — `reporter`'s generated reports have no business sitting next to `fetcher`'s raw
extraction output. A bucket is always dedicated, so a `mode` variable here would only ever accept
one value. It is omitted rather than carried as dead configuration.

## Why the uniform datastore outputs are not implemented

`endpoint`, `port`, `secret_arn` and `identifier` describe a network service reached
with a connection string. S3 has no host to resolve, no port to open and no password to rotate —
access is granted by IAM role, not by credential. Emitting those names filled with `null` would be
misleading, so this module exports what actually matters instead: the bucket names, ARNs and the
IAM policy ARNs to attach.

## Per-bucket hardening (not configurable)

- **Public access block** — all four flags on.
- **Object ownership** — `BucketOwnerEnforced`, ACLs disabled entirely.
- **Bucket policy** — denies any request not made over TLS. `require_latest_tls_policy`
  additionally denies TLS older than 1.2 (default on).
- **Encryption** — SSE-S3 (`AES256`) by default, SSE-KMS when `kms_key_arn` is set, with S3 Bucket
  Keys enabled either way.
- **Versioning** — on by default.

## IRSA: one policy per bucket

Each bucket gets its own `aws_iam_policy` granting exactly what an application needs:
`s3:ListBucket`, `s3:ListBucketMultipartUploads` and `s3:GetBucketLocation` on the bucket, plus
`s3:GetObject`, `s3:GetObjectVersion`, `s3:PutObject`, `s3:DeleteObject`,
`s3:AbortMultipartUpload` and `s3:ListMultipartUploadParts` on its objects. When `kms_key_arn` is
set the policy also grants the matching KMS actions — without them the app could write to the
bucket but never read back what it wrote.

**Per bucket rather than consolidated**, because a consolidated policy would grant every attached
principal access to every bucket in the invocation, and these buckets do not share a blast radius.
Per-bucket policies stay independently attachable and independently auditable, and IAM policies are
effectively free (1500 per account).

The IAM role is **optional**. Supply both `oidc_provider_arn` and `service_account` and this module
creates the role and attaches every policy; leave them empty and it creates policies only, for the
EKS stack to attach to a role it already manages. The `"namespace:name"` notation for
`service_account` matches what `examples/aws/infra-base/eks/iam.tf` already uses for
`namespace_service_accounts`.

## Usage — the three real products

`reporter`, with lifecycle tiering and its own IRSA role:

```hcl
module "storage" {
  source = "../../_modules/s3-bucket"

  product     = "reporter"
  environment = var.environment

  buckets = {
    "reporter-storage" = {
      transition_ia_days         = 30
      transition_glacier_days    = 90
      expiration_days            = 2555 # 7 years, regulatory retention
      noncurrent_expiration_days = 30
    }
  }

  oidc_provider_arn = data.terraform_remote_state.eks.outputs.oidc_provider_arn
  service_account   = "reporter:reporter"
}
```

`fetcher`, extraction output that ages out quickly:

```hcl
module "storage" {
  source = "../../_modules/s3-bucket"

  product     = "fetcher"
  environment = var.environment

  buckets = {
    "external-data" = {
      transition_ia_days = 15
      expiration_days    = 90
    }
  }

  oidc_provider_arn = data.terraform_remote_state.eks.outputs.oidc_provider_arn
  service_account   = "fetcher:fetcher"
}
```

`plugin-bc-correios`, attachments kept encrypted with a CMK:

```hcl
module "storage" {
  source = "../../_modules/s3-bucket"

  product     = "plugin-bc-correios"
  environment = var.environment

  buckets = {
    "bc-correios-attachments" = {
      kms_key_arn                = var.attachments_kms_key_arn
      noncurrent_expiration_days = 90
    }
  }

  oidc_provider_arn = data.terraform_remote_state.eks.outputs.oidc_provider_arn
  service_account   = "plugin-bc-correios:plugin-bc-correios"
}
```

Wiring the results into a Helm release:

```hcl
bucket_name    = module.storage.bucket_names["reporter-storage"]
irsa_role_arn  = module.storage.iam_role_arn
```

Multiple buckets in one invocation:

```hcl
buckets = {
  "reporter-storage" = { transition_ia_days = 30 }
  "reporter-exports" = { expiration_days = 30, force_destroy = true }
}
```

## Inputs

| Name                               | Type                | Default         | Description                                                                            |
| ---------------------------------- | ------------------- | --------------- | -------------------------------------------------------------------------------------- |
| `product`                          | `string`            | —               | Product owning the buckets.                                                             |
| `environment`                      | `string`            | —               | One of `dev`, `stg`, `prd`. Validated.                                                  |
| `buckets`                          | `map(object({...}))`| —               | Buckets keyed by logical name. At least one required. See the table below.               |
| `transition_ia_storage_class`      | `string`            | `"STANDARD_IA"` | `STANDARD_IA`, `ONEZONE_IA` or `INTELLIGENT_TIERING`.                                    |
| `transition_glacier_storage_class` | `string`            | `"GLACIER"`     | `GLACIER`, `GLACIER_IR` or `DEEP_ARCHIVE`.                                               |
| `require_latest_tls_policy`        | `bool`              | `true`          | Also deny TLS older than 1.2. Denying plain HTTP is unconditional.                       |
| `oidc_provider_arn`                | `string`            | `""`            | EKS IAM OIDC provider ARN. With `service_account`, creates the IRSA role.                |
| `service_account`                  | `string`            | `""`            | `"namespace:name"` of the service account allowed to assume the role.                    |
| `extra_tags`                       | `map(string)`       | `{}`            | Merged over the standard Lerian tag set.                                                 |

### `buckets` object attributes

| Attribute                                | Type                  | Default | Description                                                       |
| ---------------------------------------- | --------------------- | ------- | ----------------------------------------------------------------- |
| `versioning_enabled`                     | `bool`                | `true`  | Object versioning.                                                 |
| `kms_key_arn`                            | `string`              | `null`  | Use SSE-KMS with this CMK instead of SSE-S3.                        |
| `force_destroy`                          | `bool`                | `false` | Allow `terraform destroy` on a non-empty bucket.                    |
| `lifecycle_enabled`                      | `bool`                | `true`  | Emit a lifecycle configuration at all.                              |
| `transition_ia_days`                     | `number`              | `null`  | Days before transitioning to the IA class.                          |
| `transition_glacier_days`                | `number`              | `null`  | Days before transitioning to Glacier. Must exceed the IA value.     |
| `expiration_days`                        | `number`              | `null`  | Days before current versions expire. Must exceed both transitions.   |
| `noncurrent_expiration_days`             | `number`              | `null`  | Days before noncurrent versions expire.                             |
| `abort_incomplete_multipart_upload_days` | `number`              | `7`     | Days before abandoned multipart uploads are purged.                 |
| `cors_rules`                             | `list(object({...}))` | `[]`    | CORS rules. Empty means no CORS configuration.                      |

## Outputs

| Name                           | Description                                                                          |
| ------------------------------ | ------------------------------------------------------------------------------------ |
| `bucket_names`                 | Logical name to the real, globally unique bucket name.                                |
| `bucket_ids`                   | Logical name to bucket id.                                                            |
| `bucket_arns`                  | Logical name to bucket ARN.                                                           |
| `bucket_regional_domain_names` | Logical name to region specific domain name, for SDK endpoint configuration.          |
| `iam_policy_arns`              | Logical name to its access policy ARN. Attach these for IRSA.                          |
| `iam_policy_names`             | Logical name to its access policy name.                                               |
| `iam_role_arn`                 | IRSA role ARN, the `eks.amazonaws.com/role-arn` annotation value. `null` if not created. |
| `iam_role_name`                | IRSA role name. `null` if not created.                                                |
| `tags`                         | Standard Lerian tag set applied to every resource.                                     |

## Validation

```bash
terraform fmt -check -recursive .
terraform init -backend=false -input=false
terraform validate
```
