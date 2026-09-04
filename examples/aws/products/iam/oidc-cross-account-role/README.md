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
   ServiceAccount, and it is the boundary: every projected token in that cluster
   is signed by the same issuer, so without `:sub` any pod there could assume the
   role. `:aud` pins `sts.amazonaws.com`, which the identity provider's
   `client_id_list` already requires — belt and braces, written out because AWS
   documents pinning both, and because a second audience added to `client_id_list`
   later would otherwise widen this role silently.
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
| In | `policy_json` — the transcribed **Allow** statements; the custody Deny is appended by this root, see below |
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

That applies to the **Allow** half. The custody Deny is not transcribed at all —
this root builds it, for the reason in the next section.

## The custody Deny is built here, not required from the tfvars

**Every policy this root attaches carries the custody Deny, because the root
appends it.**

`tenants/{env}/{org}/{app}/external/` holds a client's Dataprev credential. The
gateway pays real cost for that path to be immutable: a variable validation
refuses `PutSecretValue` there, so rotation writes a *new* version path and the
audit trail cannot be rewritten. That is a property of one role unless the role
next door is refused too — and this role's Allow over `tenants/` necessarily
covers the custody ARNs. Both directions are denied: a Deny on writes alone would
still let the control plane read the credential out of the vault.

The statement the root appends:

| | |
|---|---|
| `Effect` | `Deny` |
| `Action` | the eight measured `deny_actions` of `products/tenant-manager/secrets`: `CreateSecret`, `PutSecretValue`, `UpdateSecret`, `RestoreSecret`, `DeleteSecret`, `GetSecretValue`, `BatchGetSecretValue`, `DescribeSecret` |
| `Resource` | `arn:{partition}:secretsmanager:{region}:{this account}:secret:tenants/*/*/*/external/*` — partition, region and account come from the apply itself |
| `Condition` | none |

One IAM wildcard, and it crosses `/`: `external/*` covers the measured custody
path at any depth (`external/{target}/credentials/versions/{uuid}`, plus the six
random characters Secrets Manager suffixes onto every secret ARN).

### Why it is built and not demanded

An earlier cut required `policy_json` to carry this statement and refused the
plan when it did not. That meant *recognising* a Deny — matching an ARN, a verb
list, and the absence of `Condition`/`NotAction`/`NotResource` — and every review
round found one more lookalike that read correct and denied nothing: an ARN in
another account, an ARN ending at `external/` with no trailing wildcard, a path
segment appended after the wildcard, the verb list cut to `Put`+`Get`, the whole
statement neutralised by a `Condition` that never matches.

Building the statement makes the invariant true by construction. There is no
document this root can attach without it, no regex to get right, and no error
message that has to describe the ARN correctly to be useful. A Deny of its own in
`policy_json` is additive — IAM takes the union of denies — so a tfvars that also
carries one is accepted rather than hunted for.

`tests/custody_deny.tftest.hcl` proves the construction with `mock_provider "aws"
{}` — no credential, no AWS call. It feeds a `policy_json` with **no Deny at
all** (the Allow half of the real transcription) and asserts the rendered policy
carries exactly one Deny, with those eight verbs and that ARN. Two file-level
`override_data` blocks pin `aws_caller_identity` and `aws_partition`, because the
ARN is built from the account of the apply and a mocked data source would
otherwise decide the assertion for the wrong reason.

```
terraform init -backend=false && terraform test
# Success! 1 passed, 0 failed.
```

`terraform test` with `mock_provider` needs Terraform **>= 1.7** locally. The
root's own `required_version` floor stays `>= 1.5.0`: the floor is what the roots
apply under, and this file is a local proof — the foundation's CI does not run
`terraform test` today.

## Why it lives under `products/` when it is not a product

`lerian-infra` discovers roots by walking `products/*/*` and nothing else, and
its `infra-base` stage is hardcoded to exactly `vpc` and `eks`
(`pkg/infra/discover.go:36-78`, `:128-153`). A root outside that shape has no
target, no ordering, no state key and no account guard. Precedent:
`products/lerian-platform/dns`.
