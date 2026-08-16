# infra-base/eks

Shared EKS cluster for one environment. This is base infrastructure, so it runs with
`product = "lerian"` and every name it creates derives from the naming module:

```
cluster name        lerian-{env}-eks
admin IAM role      lerian-{env}-eks-admin-role
developer IAM role  lerian-{env}-eks-developer-role
node group          lerian-{env}-eks-{node group key}
node IAM role       lerian-{env}-eks-{node group key}
KMS alias           alias/eks/lerian-{env}-eks
control plane logs  /aws/eks/lerian-{env}-eks/cluster
IRSA roles          lerian-{env}-eks-{ebs-csi,cluster-autoscaler,aws-load-balancer-controller,external-dns,cert-manager}
```

Because the environment is part of every one of those names, `dev`, `stg` and `prd`
can coexist inside a single AWS account.

## What it provisions

| Area | Detail |
|---|---|
| Control plane | `terraform-aws-modules/eks/aws ~> 21.0`, `authentication_mode = "API"` (access entries, no `aws-auth` ConfigMap) |
| Endpoint | private always on; public optional and always CIDR-restricted (`allowed_api_access_cidrs`) |
| Access | EKS access entries for the admin role (`AmazonEKSClusterAdminPolicy`) and developer role (`AmazonEKSViewPolicy`), plus the Terraform caller when `enable_cluster_creator_admin_permissions = true` |
| Secret encryption | customer managed KMS key (`terraform-aws-modules/kms/aws 1.5.0`) for etcd envelope encryption of Kubernetes secrets, key rotation on. `create_kms_key = false` on the EKS module so it does not create a second key or fight over the alias |
| Control plane logs | all five types (`api`, `audit`, `authenticator`, `controllerManager`, `scheduler`), retention configurable |
| Addons | `coredns`, `kube-proxy`, `vpc-cni`, `metrics-server`, `aws-ebs-csi-driver` (bound to its IRSA role) |
| Compute | configurable map of EKS managed node groups; IMDSv2 required, gp3 encrypted root volumes |
| Node networking | node SG rules for node-to-node, ALB health checks into the NodePort range, egress to the VPC and 443 out |
| IRSA | `ebs-csi` always; `cluster-autoscaler`, `aws-load-balancer-controller`, `external-dns` and `cert-manager` behind flags |

Nothing in this stack creates a VPC, subnets or NAT — those belong to
`infra-base/vpc`. It creates no DNS zone and no DNS record either: the ExternalDNS
and cert-manager IRSA roles below are IAM permissions over a **public** hosted zone
the client already owns, for ingress hostnames and ACME DNS-01 challenges. No stack
in this repository manages a hosted zone.

## Dependency on infra-base/vpc — the names must match

This stack does **not** create its network. It resolves it:

- VPC by `tag:Name` = `lerian-{env}-vpc` (override with `vpc_name`)
- subnets by `tags = { Type = "private" }` inside that VPC (override with `subnet_tag_type`)

The coupling that actually bites is the other direction. `infra-base/vpc` tags its
subnets with `kubernetes.io/cluster/lerian-{env}-eks`, and that string is derived
independently there from the same `{product}-{environment}-{component}` rule. EKS and
the AWS Load Balancer Controller use those tags to discover subnets, so:

> If you change `product` (or the component suffix) in one stack, you must change it
> in the other. A mismatch does not fail `terraform apply` — it fails later, quietly,
> as ingresses that never get an ALB and subnets EKS refuses to use.

Apply order: `vpc` → `eks`.

## Usage

```bash
cd examples/aws/infra-base/eks

# dev
terraform init \
  -backend-config=../../backend/dev.hcl \
  -backend-config="key=aws/infra-base/eks/terraform.tfstate"

cp envs/dev.tfvars-example envs/dev.tfvars   # then edit allowed_api_access_cidrs
terraform plan  -var-file=envs/dev.tfvars
terraform apply -var-file=envs/dev.tfvars
```

Switching environments in the same working directory needs `-reconfigure`, since the
backend key changes:

```bash
terraform init -reconfigure \
  -backend-config=../../backend/stg.hcl \
  -backend-config="key=aws/infra-base/eks/terraform.tfstate"
```

`backend.tf` holds an empty `backend "s3" {}` on purpose: bucket, region and lock
table come from `examples/aws/backend/{env}.hcl`, written by `examples/aws/bootstrap`.
The bucket is already per environment, so the state key does not repeat the env.

Then point kubectl at the cluster with the ready-made command:

```bash
$(terraform output -raw update_kubeconfig)
# aws eks update-kubeconfig --name lerian-dev-eks --region us-east-1
```

With `cluster_endpoint_public_access = false` (the prd default) that command only
works from inside the VPC — bastion, VPN or a self-hosted CI runner in a private
subnet.

### `allowed_api_access_cidrs` — why the examples ship a broken placeholder

The dev and stg `tfvars-example` files set `allowed_api_access_cidrs` to
`"<PUT-YOUR-EGRESS-IP-HERE>/32"`, which is deliberately not a valid CIDR. Fill it in
with your real public egress address before planning:

```bash
curl -s https://checkip.amazonaws.com     # -> 203.0.113.10   (exemplo; use o SEU)
# allowed_api_access_cidrs = ["<seu-ip>/32"]
```

The placeholder is broken on purpose because the two obvious alternatives are both
worse:

- **A realistic-looking example address.** The files used to ship the RFC 5737
  documentation ranges (`192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24`). Those
  are the correct blocks to write in prose, and AWS refuses them in
  `publicAccessCidrs` — copying the file unedited fails about a minute into the
  apply with `InvalidParameterException: The following CIDRs are not allowed in
  publicAccessCidrs`, after the KMS key, both IAM roles and the log group already
  exist. The EKS docs only say the list "cannot include reserved addresses" and never
  enumerate them, so the error reads as a bug in the stack rather than an unedited
  placeholder.
- **An empty list.** With `cluster_endpoint_public_access = true`, AWS treats an empty
  `publicAccessCidrs` as `0.0.0.0/0`. The apply *succeeds* and the Kubernetes API ends
  up open to the internet. `check "api_endpoint_exposure"` flags it, but a `check` is a
  warning — it does not stop the apply. An empty list is only correct in prd, where the
  public endpoint is off and the list has nothing to filter.

An invalid CIDR is the only placeholder that fails loudly, at plan time, before
anything is created. `terraform_data.api_access_cidr_guard` in `main.tf` turns it into
an error that names the fix, alongside two related guards:

| Rejected at plan time | Why |
|---|---|
| Malformed entries and IPv6 blocks | not a valid IPv4 CIDR; EKS also refuses IPv6 blocks on an IPv4 cluster |
| RFC 5737 documentation ranges, plus loopback, link-local, multicast, benchmarking, `240.0.0.0/4` and the other IANA special-purpose blocks | AWS refuses them in `publicAccessCidrs` — no apply can succeed |
| RFC 1918 private ranges and RFC 6598 CGNAT | this list only filters traffic reaching the **public** endpoint, where the source address is always public, so these match nobody while looking like they allowlist the office. In-VPC access is what `cluster_endpoint_private_access` is for |

`0.0.0.0/0` is deliberately *not* a plan error: AWS accepts it, so it is a judgement
about exposure rather than an impossible apply, and bootstrapping from a dynamic
address is a real reason to open it for one apply. It raises the
`check "api_endpoint_exposure"` warning instead — the same warning the empty-list case
raises, since the exposure is identical.

## Environment sizing

| | dev | stg | prd |
|---|---|---|---|
| Node groups | 1 (`default`) | 1 (`general`) | 2 (`general` + tainted `heavy`) |
| Instances | `t3.medium` x86, 2 nodes | `c7g.large` ARM, 3 nodes | `c7g.xlarge` + `c7g.2xlarge` ARM |
| Root disk | 20 GB | 50 GB | 100 / 150 GB |
| API endpoint | public, IP allowlisted | public, IP allowlisted | private only |
| Log retention | 7 days | 30 days | 90 days |
| Autoscaler / LB controller | off | on | on |
| ExternalDNS / cert-manager | off | off | on |

Node group sizing guidance by TPS lives in the `node_groups` variable description.
ARM (`c7g.*` with an `AL2_ARM_64` / `AL2023_ARM_64_STANDARD` ami_type) gives 21-37%
better price/performance; burstable `t3.*`/`t4g.*` are for non-production only.

`disk_size = null` keeps the AMI default root volume. Any other value produces a
gp3, encrypted `/dev/xvda` root volume — which assumes an Amazon Linux root device
layout. Bottlerocket splits os/data volumes and needs its own launch template, which
this stack does not model.

## What still has to be installed after apply

This stack creates **IAM roles, not controllers**. Nothing below can be installed
through the EKS `addons` block; each one is a Helm chart, installed manually, by
GitOps, or by whatever pipeline the client uses. Wire the matching role ARN onto the
controller's service account (`eks.amazonaws.com/role-arn` annotation).

| Component | Needed when | Role ARN output | Service account |
|---|---|---|---|
| [Cluster Autoscaler](https://artifacthub.io/packages/helm/cluster-autoscaler/cluster-autoscaler) | node count should follow demand | `cluster_autoscaler_role_arn` | `kube-system:cluster-autoscaler` |
| [AWS Load Balancer Controller](https://artifacthub.io/packages/helm/aws/aws-load-balancer-controller) | exposing APIs through an internal ALB (or a public one, not recommended) | `load_balancer_controller_role_arn` | `kube-system:aws-load-balancer-controller` |
| [NGINX Ingress Controller](https://artifacthub.io/packages/helm/ingress-nginx/ingress-nginx) | client standardises on NGINX ingress | none required | — |
| [ExternalDNS](https://artifacthub.io/packages/helm/external-dns/external-dns) | Services/Ingresses should publish their hostnames into a Route53 hosted zone the client owns | `external_dns_role_arn` | `kube-system:external-dns` |
| [cert-manager](https://artifacthub.io/packages/helm/cert-manager/cert-manager) | TLS certificates via Route53 DNS-01 | `cert_manager_role_arn` | `cert-manager:cert-manager` |

Notes:

- The Cluster Autoscaler also needs the ASG auto-discovery tags. This stack adds
  `k8s.io/cluster-autoscaler/enabled` and `k8s.io/cluster-autoscaler/lerian-{env}-eks`
  to every node group whenever `create_autoscaler_role = true`.
- The AWS Load Balancer Controller discovers subnets from the tags set by
  `infra-base/vpc` (`kubernetes.io/role/elb` on public, `kubernetes.io/role/internal-elb`
  on private) — see the name-matching warning above.
- Narrow `external_dns_hosted_zone_arns` and `cert_manager_hosted_zone_arns` from the
  default `hostedzone/*` to the id of the hosted zone the cluster actually has to
  write into, before prd. No stack in this repository creates that zone — it is the
  client's public zone for ingress hostnames and DNS-01 challenges.
- Products deploying with Amazon MQ must set `RABBITMQ_URI: "amqps"` in their Helm
  values for any component using cloud AMQP.

## Outputs consumed by other stacks

| Output | Consumer |
|---|---|
| `oidc_provider_arn` | `_modules/s3-bucket` and any product stack minting IRSA roles against this cluster |
| `oidc_provider_url` / `oidc_provider` | IAM trust policies written by hand (`<issuer>:sub` condition keys) |
| `cluster_name` | Helm/GitOps values, `kubernetes.io/cluster/<name>` tags, autoscaler discovery |
| `cluster_endpoint`, `cluster_certificate_authority_data` | kubeconfig generation, CI runners, ArgoCD cluster registration |
| `cluster_primary_security_group_id`, `node_security_group_id` | datastore modules, as the source security group for RDS/DocumentDB/Valkey/AmazonMQ ingress |
| `kms_key_arn` | audit evidence that secrets are envelope-encrypted with a CMK |
| `admin_role_arn`, `developer_role_arn` | the roles humans assume before `kubectl` |
| `update_kubeconfig` | copy-paste onboarding command |

## Migration notes (from the pre-v2 `examples/aws/eks` stack, removed in v2)

Same modules, same versions, same node SG rules and addons. What changed:

1. `var.name` (default `midaz-eks`) is gone. `product` + `environment` feed the naming
   module instead; `environment` has no default and is validated against dev/stg/prd.
2. IAM role names, the KMS alias, node group names and node IAM role names all come
   from `module.naming.name`. Previously `midaz-eks-admin-role` and
   `midaz-eks-default-nodepool` were environment-less with `use_name_prefix = false`,
   so a second environment in the same account collided on apply.
3. The KMS alias dropped its duplicated environment (`eks/midaz-eks-dev` →
   `eks/lerian-dev-eks`), and `create_kms_key = false` was added to the EKS module so
   it stops creating a second, unused key aliased off the cluster name.
4. `vpc_name` is now derived (`lerian-{env}-vpc`) instead of being a required literal.
5. The single hardcoded `default` node group became the `node_groups` map. The
   per-node-group `instance_types` allowlist was relaxed — it rejected `t3.medium`,
   which dev needs — and the TPS guidance moved into the variable description.
6. `additional_tags` became `extra_tags`, passed through the naming module so every
   resource carries `Product`, `Environment`, `ManagedBy` and `Repository`.
7. Added: `external-dns` and `cert-manager` IRSA flags, `oidc_provider_arn` /
   `oidc_provider_url` outputs, `update_kubeconfig` output, configurable control plane
   log retention, and a `check` block that fails the plan when the public endpoint is
   enabled with an empty CIDR allowlist.

Known upstream warning: `terraform validate` reports a deprecated
`data.aws_region.current.name` inside `terraform-aws-modules/iam ~> 5.33` under AWS
provider 6.x. Warning only; it clears when that module is bumped to 6.x repo-wide.
