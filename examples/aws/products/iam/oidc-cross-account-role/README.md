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

The guard accepts a statement only when all four hold:

- `"Effect": "Deny"`,
- a `Resource` matching `secret:tenants/*/*/*/external/`,
- an `Action` list carrying **both** `secretsmanager:PutSecretValue` and
  `secretsmanager:GetSecretValue`,
- **no `Condition`, `NotAction` or `NotResource`** on that statement.

Both directions, deliberately: a Deny on writes alone would still let the control
plane read a client's credential out of the vault. A bare `secretsmanager:*` is
**not** accepted — the measured document lists eight verbs there nominally, and
the guard demands the verbs rather than guessing which wildcards subsume them.

The fourth condition is the one that catches the lookalike. A `Deny` is only
unconditional when nothing narrows it, and each of the three forbidden keys
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

`tests/custody_deny.tftest.hcl` proves it in three directions with
`mock_provider "aws" {}` — no credential, no AWS call: the Deny present (plans
clean), the Deny deleted (refused), and the Deny narrowed by a `Condition`
(refused).

```
terraform init -backend=false && terraform test
# Success! 3 passed, 0 failed.
```

The foundation's CI does not run `terraform test` today, so this proof is local.

## Why it lives under `products/` when it is not a product

`lerian-infra` discovers roots by walking `products/*/*` and nothing else, and
its `infra-base` stage is hardcoded to exactly `vpc` and `eks`
(`pkg/infra/discover.go:36-78`, `:128-153`). A root outside that shape has no
target, no ordering, no state key and no account guard. Precedent:
`products/lerian-platform/dns`.
