# `products/iam/oidc-cross-account-role`

The identity the control plane uses to provision in the application account.

`tenant-manager` runs in the control-plane account (Terraform environment `dev`)
and provisions the datastores, tenants and secrets that live in the application
account. Its ServiceAccount carries exactly one
`eks.amazonaws.com/role-arn` annotation, and the role that annotation names lives
**here**, next to the resources it touches — not next to the pod that assumes it.

Applies in the application account, **once**, as environment `prd`.

## Three parts, all of them load-bearing

1. **A copy of the peer cluster's OIDC issuer** as an identity provider in this
   account. Without it, a token minted by the control-plane cluster is not a
   principal this account recognises and no trust policy can name it.
2. **A trust policy pinning `:sub` and `:aud`.** `:sub` is the exact
   ServiceAccount. `:aud` is `sts.amazonaws.com` — and without it *any* pod in
   the control-plane cluster can assume the role, because every projected token
   in that cluster is signed by the same issuer.
3. **The grants**, as one inline policy, transcribed from the in-account role
   this one replaces.

## One role for both stacks

Staging and production share this AWS account, so one role reaches both. The
isolation between the stacks is in the Secrets Manager path grammar the policy
scopes to (`tenants/staging/…` vs `tenants/production/…`), not in a second role:
two roles with the same trust and the same reach would be two things to keep
equal, which is one more than can be kept equal.

## What goes in, what comes out

| | |
|---|---|
| In | `oidc_issuer_url` — `aws eks describe-cluster --name lerian-dev-eks --query cluster.identity.oidc.issuer`, in the OTHER account |
| In | `oidc_thumbprint` — defaulted to the AWS-managed root CA; override only if AWS rotates it |
| In | `sa_subject` — `platform:tenant-manager` |
| In | `role_name` — copied verbatim into the ServiceAccount annotation in the control-plane chart |
| In | `policy_json` — the transcription; see below |
| In | `additional_policy_names` — the two S3 policies `products/tenant-manager/s3` emits |
| Out | `role_arn` (goes in the annotation), `oidc_provider_arn`, `sa_subject` |

Deploy order: `infra-base/eks` over there for the issuer URL →
`products/tenant-manager/s3` here for the borrowed policies → this root.
Attaching a policy that does not exist yet fails with `NoSuchEntity`, which is
loud rather than silent.

## Why the policy is a transcription and not a set of knobs

The document has to equal what `_modules/irsa-secretsmanager` emits today from
`products/tenant-manager/secrets` — that in-account role is the identity this
one replaces. A knob-built policy would look tidier and would drift from the
thing it is supposed to equal, so the content lives in the tfvars where it can be
diffed against its source and argued with in review.

## The custody guard

**The plan fails when `policy_json` carries no unconditional custody Deny.**

`tenants/{env}/{org}/{app}/external/` holds a client's Dataprev credential. The
gateway pays real cost for that path to be immutable: a variable validation
refuses `PutSecretValue` there, so rotation writes a *new* version path and the
audit trail cannot be rewritten. That is a property of one role unless the role
next door is refused too — and this role's Allow over `tenants/` necessarily
covers the custody ARNs.

The guard accepts a statement only when all five hold:

- `"Effect": "Deny"`,
- a `Resource` naming the custody path **of this account, in this region, with
  its trailing wildcard** — matching
  `arn:<partition>:secretsmanager:<this region or *>:<this account or *>:secret:tenants/*/*/*/external/*`,
- an `Action` list carrying **all eight** verbs of the measured `deny_actions`:
  `CreateSecret`, `PutSecretValue`, `UpdateSecret`, `RestoreSecret`,
  `DeleteSecret`, `GetSecretValue`, `BatchGetSecretValue`, `DescribeSecret`,
- **no `Condition`**, **no `NotAction`** and **no `NotResource`** on that
  statement.

Both directions, deliberately: a Deny on writes alone would still let the control
plane read a client's credential out of the vault. A bare `secretsmanager:*` is
**not** accepted — the measured document lists eight verbs there nominally, and
the guard demands the verbs rather than guessing which wildcards subsume them.

The ARN and the verb list are pinned that tightly because three transcriptions
read correct in review and deny nothing:

| Lookalike | Why it denies nothing |
|---|---|
| ARN scoped to another account or region | IAM evaluates it against secrets that do not exist here. The custody path in *this* account stays writable and readable. A tfvars copied from another estate arrives exactly this way. |
| ARN ending in `external/` with no trailing `*` | Secrets Manager suffixes six random characters onto every secret ARN, so the statement matches no real secret. The likeliest hand-copy slip on the page. |
| `Action` narrowed to `PutSecretValue` + `GetSecretValue` | Leaves `CreateSecret`/`UpdateSecret` (overwrite the credential by another door), `DeleteSecret`/`RestoreSecret`, and `BatchGetSecretValue`/`DescribeSecret` (read and enumerate it) allowed on the custody ARNs. |

The fifth condition is the one that catches the subtlest lookalike. A `Deny` is
only unconditional when nothing narrows it, and each of the three forbidden keys
narrows it while leaving a document that still reads correct in review:

| Key | What it does to the Deny |
|---|---|
| `Condition` | AWS evaluates the Deny only when the condition matches. `"aws:PrincipalTag/never": "matches"` denies nobody, and the statement is otherwise identical to the real one. |
| `NotAction` | Denies every verb **except** the eight listed — the inverse of the intent. |
| `NotResource` | Denies every ARN **except** the custody path — the inverse again. |

The measured document (`deny_actions` + `deny_secret_path_patterns` in
`products/tenant-manager/secrets`) carries none of the three, so demanding their
absence costs the transcription nothing.

It is a `precondition` and not a variable `validation` because the check decodes
the document and walks its statements, and locals are not reachable from a
validation block on every version this repository supports. Same mechanism
`_modules/irsa-secretsmanager` already uses (`main.tf:103,111`).

`tests/custody_deny.tftest.hcl` proves it in six directions with
`mock_provider "aws" {}` — no credential, no AWS call: the Deny present (plans
clean), and five refusals — the Deny deleted, the Deny narrowed by a
`Condition`, the Deny scoped to another account, the Deny missing the trailing
wildcard, and the Deny carrying only `PutSecretValue` + `GetSecretValue`. Two
file-level `override_data` blocks pin `aws_caller_identity` and `aws_partition`,
because the guard anchors the ARN to the account of the apply and a mocked data
source would otherwise decide the fixtures for the wrong reason.

```
terraform init -backend=false && terraform test
# Success! 6 passed, 0 failed.
```

The foundation's CI does not run `terraform test` today, so this proof is local.

## Why it lives under `products/` when it is not a product

`lerian-infra` discovers roots by walking `products/*/*` and nothing else, and
its `infra-base` stage is hardcoded to exactly `vpc` and `eks`
(`pkg/infra/discover.go:36-78`, `:128-153`). A root outside that shape has no
target, no ordering, no state key and no account guard. Precedent:
`products/lerian-platform/dns`.
