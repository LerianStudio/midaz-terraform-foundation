# products/plugin-bc-correios/s3

The object storage of the **plugin-bc-correios** product. In the Helm chart this role is
filled by SeaweedFS; on AWS it becomes S3.

| | |
| --- | --- |
| Module | [`_modules/s3-bucket`](../../../_modules/s3-bucket) |
| Logical bucket | `bc-correios-attachments` |
| Real name | `plugin-bc-correios-{env}-bc-correios-attachments-{account_id}` |
| State key | `aws/products/plugin-bc-correios/s3/terraform.tfstate` |
| Chart | `plugin-bc-correios-helm 2.2.0 (appVersion 1.2.0)` |

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
| literal `"s3"` | `OBJECT_STORAGE_PROVIDER` | `bc-correios.configmap` |
| `bucket_name` | `OBJECT_STORAGE_BUCKET` | `bc-correios.configmap` |
| `"https://s3.${region}.amazonaws.com"` | `OBJECT_STORAGE_ENDPOINT` | `bc-correios.configmap` |
| literal `"false"` | `OBJECT_STORAGE_PATH_STYLE` | `bc-correios.configmap` |
| IRSA (`iam_role_arn`) | `OBJECT_STORAGE_ACCESS_KEY` / `OBJECT_STORAGE_SECRET_KEY` left empty | `bc-correios.secrets` |

Annotate the ServiceAccount with
`eks.amazonaws.com/role-arn: <iam_role_arn>`.

## Gotchas

- **The discovery note for this product was wrong.** It listed `SEAWEEDFS_HOST`
  and `SEAWEEDFS_FILER_PORT` as the contract. Neither key exists in this chart.
  The only occurrence of the string is a local shell variable inside the init
  container, derived *from* `OBJECT_STORAGE_ENDPOINT` — and that whole branch is
  wrapped in `{{- if .Values.seaweedfs.enabled }}`, so turning SeaweedFS off
  removes it. **This is the product where the SeaweedFS-to-S3 move is cleanest:
  the chart already speaks S3**, with `OBJECT_STORAGE_PROVIDER: "s3"` as its own
  default.
- **`OBJECT_STORAGE_ENDPOINT` must be set explicitly.**
  `templates/configmap.yaml` renders it as
  `... | default (printf "http://%s-seaweedfs:8333" ...)`, so an empty value is
  *not* "let the SDK resolve" — it is the in-cluster SeaweedFS service.
- **There is no region key in this chart**, unlike reporter and fetcher.
  **CONFIRMAR** how the SDK learns the region: with IRSA the EKS pod identity
  webhook injects `AWS_REGION` and `AWS_DEFAULT_REGION`, which is normally
  enough, but there is no `OBJECT_STORAGE_REGION` to fall back on. If an explicit
  value is needed it has to arrive through `bc-correios.extraEnvVars` as
  `AWS_REGION`.
- **The credential key is `OBJECT_STORAGE_ACCESS_KEY`, without the `_ID` suffix**
  the other two products use. The three products do not share a credential
  contract either. **CONFIRMAR** the default-credential-chain fallback, as for
  the other two.
- **`kms_key_arn` is left null in prd and that is a decision to revisit.** The
  module supports SSE-KMS and extends the bucket policy with the matching KMS
  actions when a key is given — but it does not create the key, and this
  repository provisions no CMK for S3. Until one exists the bucket is encrypted
  with SSE-S3 (AES256) and Bucket Keys, which is not "unencrypted". See
  `envs/prd.tfvars-example`.
- The chart ships `seaweedfs.enabled: true` and runs SeaweedFS from its own
  inline manifests (`templates/seaweedfs.yaml`), **not** from a subchart — there
  is no `seaweedfs` entry in `Chart.yaml`. Setting `seaweedfs.enabled: false`
  removes both the workload and the init container's wait.

## Validation

```bash
terraform fmt -check -recursive .
terraform init -backend=false -input=false
terraform validate
tflint --config=../../../../../.tflint.hcl
trivy config . --severity HIGH,CRITICAL --tf-exclude-downloaded-modules --quiet
```
