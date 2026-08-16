# products/fetcher/s3

The object storage of the **fetcher** product. In the Helm chart this role is
filled by SeaweedFS; on AWS it becomes S3.

| | |
| --- | --- |
| Module | [`_modules/s3-bucket`](../../../_modules/s3-bucket) |
| Logical bucket | `external-data` |
| Real name | `fetcher-{env}-external-data-{account_id}` |
| State key | `aws/products/fetcher/s3/terraform.tfstate` |
| Chart | `fetcher-helm 3.1.0 (appVersion 3.0.2)` |

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
| `bucket_name` | `OBJECT_STORAGE_BUCKET` | **`worker.configmap`** |
| `var.region` | `OBJECT_STORAGE_REGION` | **`worker.configmap`** |
| `"https://s3.${region}.amazonaws.com"` | `OBJECT_STORAGE_ENDPOINT` | **`worker.configmap`** |
| literal `"false"` | `OBJECT_STORAGE_USE_PATH_STYLE` | **`worker.configmap`** |
| *unknown* | `STORAGE_PROVIDER` | **not emitted — see below** |

Not emitted: `STORAGE_PROVIDER` (the switch; its S3 value is undocumented),
`OBJECT_STORAGE_KEY_PREFIX` (an application-chosen key namespace),
`OBJECT_STORAGE_ACCESS_KEY_ID` / `OBJECT_STORAGE_SECRET_KEY` (credentials).

Annotate the ServiceAccount with
`eks.amazonaws.com/role-arn: <iam_role_arn>`.

## Gotchas

- **The object storage keys are on the WORKER only.** They live in
  `worker.configmap`, which `templates/worker/configmap.yaml` renders alone —
  the manager never receives them. Merging them into `common.configmap` is
  harmless but hides the fact that the manager has no object storage
  configuration today. If the manager ever needs to read an object, that is a
  **chart** change.
- **`STORAGE_PROVIDER` is the switch and its S3 value is unknown.**
  `values.yaml` ships `STORAGE_PROVIDER: "seaweedfs"` and no template branches
  on it, so the accepted values live in the application. `"s3"` is the obvious
  guess and a guess is exactly what must not be emitted. **Until it is
  confirmed, setting the `OBJECT_STORAGE_*` keys has no effect** — the
  application keeps using the SeaweedFS driver.
- **The SeaweedFS keys are real here and unmappable.** Unlike reporter, this
  chart carries `SEAWEEDFS_HOST`, `SEAWEEDFS_FILER_PORT` and `SEAWEEDFS_TTL` in
  the **live** `common.configmap`. They address the filer API, which is not S3:
  a filer host has no regional-endpoint equivalent, and `SEAWEEDFS_TTL` is a
  client-side object TTL whose S3 counterpart is the server-side lifecycle
  expiration this root already creates from `expiration_days`. **CONFIRMAR
  whether the application ignores them when `STORAGE_PROVIDER` is not
  seaweedfs**; if it reads them unconditionally, the S3 path needs a chart change
  before it can be used at all.
- **CONFIRMAR: default credential chain when the credential keys are empty?**
  IRSA depends on it — same open question as reporter.
- The fetcher chart already ships `seaweedfs.enabled: false`.

## Validation

```bash
terraform fmt -check -recursive .
terraform init -backend=false -input=false
terraform validate
tflint --config=../../../../../.tflint.hcl
trivy config . --severity HIGH,CRITICAL --tf-exclude-downloaded-modules --quiet
```
