# `products/br-consignado-gw/s3`

The only WORM storage on the estate. It holds averbação artefacts — the evidence
trail behind payroll-deducted loans.

## The boot-time contract

The gateway reads the bucket's Object Lock configuration on startup and **refuses to
start** unless it finds a default retention of at least **1827 days (five years)**.
The mode it writes with is pinned to **COMPLIANCE** in its own code.

Under GOVERNANCE a principal holding `s3:BypassGovernanceRetention` can delete a
retained object early. Under COMPLIANCE nobody can — not the account root, not AWS
support — until retention expires. That is what makes the artefact evidence rather
than a file.

## It cannot be fixed after the fact

Object Lock is settable **only at bucket creation**. A bucket created without it has
to be replaced and every object re-uploaded — and objects already written under
COMPLIANCE cannot be deleted, so the wrong bucket cannot even be cleaned up. The
variable validations in this root exist to fail the plan before that happens.

## Two IAM subtleties

**`s3:PutObjectRetention` is required even though no API by that name is called.**
AWS evaluates it on any `PutObject` carrying `ObjectLockRetainUntilDate`, which is
exactly how the gateway writes. Omit it and every custody write fails with
AccessDenied naming an action nobody can find in the code.

**`s3:ListBucketVersions` is not covered by `s3:ListBucket`.** The retained-storage
client enumerates by version when recovering a partially written artefact.

`_modules/s3-bucket` grants both automatically when `object_lock_enabled` is true,
and never grants `s3:BypassGovernanceRetention`.

## No lifecycle expiry

An expiration rule cannot delete a COMPLIANCE-locked object; it only accumulates
silent, repeated lifecycle failures while looking like a working retention policy.
Retention is the policy here.

## One role, decided

This root runs with `irsa_enabled = false`: it creates the bucket and the attachable
policy, and **no role**. The policy is attached to the vault role by
`../secrets`, through `additional_policy_names`.

A ServiceAccount carries exactly one `role-arn` annotation, so two roles was never a
workable end state — applying both and annotating with one produces a gateway that
reads the vault and cannot write custody artefacts, discovered on the first
averbação.

Two consequences: **apply this root before `../secrets`** (an attachment to a policy
that does not exist fails with `NoSuchEntity`), and with no role to create there is
no OIDC lookup, so this root no longer depends on `infra-base/eks`.
