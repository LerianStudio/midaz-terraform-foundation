# products/reporter/s3

The object storage of the **reporter** product. In the Helm chart this role is
filled by SeaweedFS; on AWS it becomes S3.

| | |
| --- | --- |
| Module | [`_modules/s3-bucket`](../../../_modules/s3-bucket) |
| Logical bucket | `reporter-storage` |
| Real name | `reporter-{env}-reporter-storage-{account_id}` |
| State key | `aws/products/reporter/s3/terraform.tfstate` |
| Chart | `reporter-helm 3.2.0 (appVersion 2.3.0)` |

The account id suffix is the documented naming exception: S3 bucket names are
globally unique across every AWS account.

## This root is shaped differently from its siblings

Three things that hold for every datastore root do not hold here, and each is a
property of S3 rather than an omission.

**No `mode`.** `_modules/s3-bucket` has no `mode` input. A bucket costs nothing
when empty and its contents are the private data of exactly one product, so
there is no shared bucket tier to resolve and a `mode` variable would only ever
accept `"dedicated"`. The `mode` **output** is still published, as the constant
`"dedicated"`, so `terraform output mode` keeps working across every root of this
product.

**No ingress.** S3 is a regional API endpoint, not a host inside the VPC, so
there is no security group, no subnet placement and no `ingress_*` output.
`module.network` is still called — with `enabled = false`, which performs no AWS
lookup at all — purely to derive the EKS cluster name.

**No `endpoint` / `port` / `secret_arn` / `secret_name` / `identifier`.** Those
describe a network service reached with a connection string. Access here is by
IAM role, not by credential. Emitting them filled with `null` would leave a
consumer unable to tell "this has no endpoint" from "the lookup failed".

## IRSA — where `oidc_provider_arn` comes from

`_modules/s3-bucket` creates the IAM role a pod assumes, given
`oidc_provider_arn` and `service_account`. This root **derives** the first from
the cluster name:

```
lerian-{env}-eks  ->  data.aws_eks_cluster  ->  issuer URL
                    ->  data.aws_iam_openid_connect_provider  ->  ARN
```

Two alternatives were rejected. `terraform_remote_state` on `infra-base/eks`
would couple a product stack to the foundation's state layout *and* its backend
credentials — the same coupling `_modules/mongodb-documentdb` rejected when it
chose a data source for shared mode. A hand-copied ARN in the tfvars is a
hundred-character string that silently rots when the cluster is replaced; it is
kept as `var.oidc_provider_arn` for the case where the cluster is not ours, but
it is not the default path.

**The consequence is a harder prerequisite than the datastore roots have.** They
tolerate a missing cluster because their EKS lookup is the *plural*
`data "aws_security_groups"`. Both lookups here are singular and fail the plan.
`infra-base/eks` must exist first, or `irsa_enabled = false` must be set — which
emits the per-bucket IAM policies only, for an EKS stack that manages its own
roles.

## Outputs

`bucket_name`, `bucket_arn`, `bucket_regional_domain_name` for the one bucket the
chart consumes, the same three as maps for every bucket, `iam_role_arn` /
`iam_role_name` / `iam_policy_arns`, the resolved `oidc_provider_arn` and
`service_account`, plus `mode` and `eks_cluster_name`.

Compare `oidc_provider_arn` against the output of the same name in
`infra-base/eks`: it is the cheapest way to confirm the derivation found the
right cluster.

## Helm handoff

```bash
terraform output -json helm_values | jq
```

| Terraform | Chart env var | Destination |
| --- | --- | --- |
| `bucket_name` | `OBJECT_STORAGE_BUCKET` | `common.configmap` |
| `var.region` | `OBJECT_STORAGE_REGION` | `common.configmap` |
| `"https://s3.${region}.amazonaws.com"` | `OBJECT_STORAGE_ENDPOINT` | `common.configmap` |
| literal `"false"` | `OBJECT_STORAGE_USE_PATH_STYLE` | `common.configmap` |
| literal `"false"` | `OBJECT_STORAGE_DISABLE_SSL` | `common.configmap` |
| IRSA (`iam_role_arn`) | `OBJECT_STORAGE_ACCESS_KEY_ID` / `OBJECT_STORAGE_SECRET_KEY` left empty | `secrets` |

Annotate the ServiceAccount with
`eks.amazonaws.com/role-arn: <iam_role_arn>`.

## Gotchas

- **The discovery note for this product was out of date.** It listed
  `SEAWEEDFS_HOST` and `SEAWEEDFS_FILER_PORT` as the object storage contract.
  Those keys survive only in `values-template.yaml`, which is **stale**:
  `values.yaml` replaced them with an S3-shaped `OBJECT_STORAGE_*` block, and no
  template in the chart reads a `SEAWEEDFS_*` key. They are not emitted and
  should not be set.
- **CONFIRMAR: is an empty `OBJECT_STORAGE_ENDPOINT` "use the SDK resolver"?**
  That would be the better AWS configuration — dualstack, FIPS and future
  regional endpoints for free — but the chart default is a non-empty SeaweedFS
  URL, so "empty means default" is demonstrated nowhere. An explicit regional
  endpoint is emitted because it is the value that certainly works.
- **CONFIRMAR: does the application fall back to the AWS default credential chain
  when the two credential keys are empty?** IRSA depends on it. If the
  application instead requires a static key pair, IRSA cannot be used and an
  access key has to be issued and rotated — a different design, not a different
  value. **This is the one place where "S3 instead of SeaweedFS" is more than a
  host change.**
- The reporter chart ships `seaweedfs.enabled: true` with a PVC-backed master and
  volume. Set it to `false` or the cluster runs a filer nobody writes to.

## Validation

```bash
terraform fmt -check -recursive .
terraform init -backend=false -input=false
terraform validate
tflint --config=../../../../../.tflint.hcl
trivy config . --severity HIGH,CRITICAL --tf-exclude-downloaded-modules --quiet
```
