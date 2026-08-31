# `products/tenant-manager/secrets`

The widest identity on the estate, because tenant-manager is the thing that
provisions tenants.

## Seven vault actions, not two

`GetSecretValue`, `DescribeSecret`, `CreateSecret`, `PutSecretValue`,
`RestoreSecret`, `DeleteSecret`, `ListSecrets`. It **upserts**, unlike the gateway,
and `RestoreSecret` is a live path: it soft-deletes with a 7 day recovery window and
resurrects on re-provision. `TagResource` is never called and is not granted.

## Why the scope is the two roots rather than an environment

Three measured path shapes make a tighter prefix wrong, each failing as a 404
mid-provisioning rather than as a plan error:

1. `clusters/production/{dbType}/{service}/shared/admin` in production versus
   `clusters/{env}/{dbType}/shared/admin` everywhere else.
2. Several provisioning handlers pass the environment as the **empty string**,
   dropping the segment entirely.
3. One path writes `tenants/{tenantID}/{stackName}/admin` with UUID dashes intact
   and no env segment, unlike every other builder.

Narrow it after those are fixed upstream, not before.

## Everything beyond the vault is opt-in and empty by default

tenant-manager drives CloudFormation, RDS, DocDB, EC2 describe and S3 with this same
identity, and **every one of those initialisers soft-fails**: it logs a warning and
disables the feature rather than refusing to boot. So the service comes up healthy
with none of them, which is what the minimal wire wants. Turning any on is a real
decision — a `CreateStack` grant is effectively a grant of everything those
templates create — so it is written in the tfvars where it can be reviewed.

**Not needed: `kafka:*`.** MSK users and ACLs go over the Kafka wire protocol with
franz-go. What that needs is network egress to the broker port, which is a security
group.
