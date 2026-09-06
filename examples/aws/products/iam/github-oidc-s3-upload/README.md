# `products/iam/github-oidc-s3-upload`

The identity a repository's release pipeline uses to publish migrations into
this account's migrations bucket.

The tenant manager reads a service's SQL migrations out of an S3 bucket in the
**application** account, under `{channel}/{service}/{module}/{dbType}/`. The
files get there from the service's release pipeline: go-release's `S3 Upload`
job copies them on every tag.

That job does **not** assume a role from another AWS account. It asks GitHub for
a fresh OIDC token and calls `sts:AssumeRoleWithWebIdentity` with
`audience=sts.amazonaws.com` — so the principal the trust policy has to name is
**GitHub's OIDC provider**, and it has to exist in this account first.

Applies in the account that owns the bucket, **once**, as environment `prd`.

## Three parts, all of them load-bearing

1. **GitHub's OIDC issuer as an identity provider in this account.** Without it,
   a token minted by GitHub Actions is not a principal this account recognises
   and no trust policy can name it. No thumbprint is pinned: since 2023 AWS
   validates `token.actions.githubusercontent.com` against its own trust store
   and ignores the recorded value.
2. **A trust policy pinning `:sub` to tag pushes of one repository, and `:aud`.**
   Every GitHub Actions token in the world is signed by the same issuer, so
   `:sub` is the entire boundary. `StringLike` is on the **tag name**, never on
   the repository: `repo:OWNER/REPO:ref:refs/tags/*`. A branch push carries a
   different subject and is refused, which is what keeps a workflow edited in a
   fork's pull request away from the bucket.
3. **One inline policy, one verb.** `s3:PutObject` over
   `{channel}/{repo}/*` for the three release channels, and nothing else.

## Why the role lives here and not next to the pipeline

It lives in the account that **owns the bucket**. That is what makes a bucket
policy unnecessary — an in-account role with `s3:PutObject` is enough, and
`_modules/s3-bucket` does not have to grow a bucket-policy input it has never
needed.

## Why the channels are derived, not configured

go-release picks the top-level folder from the tag's channel:

| tag                         | folder         |
| --------------------------- | -------------- |
| `*-beta*`                   | `development/` |
| `*-rc*`                     | `staging/`     |
| `vX.Y.Z`                    | `production/`  |

An `s3_uploads` entry is **not** conditional on the channel — it runs on every
tag the repository cuts. A service that cuts a beta on each merge to `develop`
writes to `development/` constantly, so a policy listing only `production/`
turns every merge into a red `S3 Upload` job: the step runs under
`set -euo pipefail`, and one `AccessDenied` kills it.

Listing the three folders in a tfvars would make "all the channels, and only the
channels" something a reviewer has to remember. The root derives them, and the
cost of the folders nothing reads today is zero.

## What is deliberately absent

- **`s3:DeleteObject`.** The tenant manager decides what to run by comparing the
  migrations a tenant has applied against the ones available in the bucket.
  Removing a `.sql` a tenant already applied puts a hole in that comparison. A
  release pipeline only ever adds files.
- **`s3:ListBucket`.** go-release copies each file by key. Listing is the
  reader's job, and the reader is not this identity.
- **A thumbprint.** See above; a pinned fingerprint here would rot on rotation
  and read as a control that is not one.

## Deploy order

1. the bucket — `products/tenant-manager/s3`, here;
2. **this root**;
3. the `aws_role_arn` field of the `s3_uploads` entry in the other repository's
   `release.yml`.

Until step 3 lands, nothing assumes this role.

> The organisation secret `AWS_MIGRATIONS_ROLE_ARN` must also reach the
> repository. go-release's `Configure AWS credentials` step runs before the loop
> over `s3_uploads` entries, so an empty secret kills the job before any entry —
> including the entries that carry their own `aws_role_arn`.

## Inputs

| name                     | required | notes                                                              |
| ------------------------ | -------- | ------------------------------------------------------------------ |
| `environment`            | yes      | `prd` — the role is a property of the account, not of a stack       |
| `github_repository`      | yes      | `owner/repo`; names both the trust subject and the object prefixes  |
| `role_name`              | yes      | copied verbatim into the other repository's `release.yml`           |
| `migrations_bucket_name` | yes      | a bucket **name**, not an ARN                                       |
| `region`                 | no       | provider endpoint and tags only; S3 ARNs carry no region            |
| `extra_tags`             | no       |                                                                     |

## Verification after apply

```bash
aws iam list-open-id-connect-providers | grep -c 'token.actions.githubusercontent.com'   # 1
aws iam get-role --role-name "$ROLE" \
  --query 'Role.AssumeRolePolicyDocument' | grep -o 'repo:[^"]*'
aws iam get-role-policy --role-name "$ROLE" --policy-name "$ROLE-policy" \
  --query 'PolicyDocument.Statement[].Resource' --output text
```
