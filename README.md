# Lerian Terraform Foundation

Terraform templates for the infrastructure the Lerian products run on: the network, the
Kubernetes cluster, and the datastores each product needs.

On **AWS** the templates are driven by `lerian-infra`, a CLI that ships from this
repository. On **GCP and Azure** they are driven by `./deploy-legacy.sh`, an
interactive script over an earlier layout.

Pick your cloud and follow that section. Read [Important
information](#important-information) before deploying anything to production.

## Support matrix

| Stack | AWS | GCP | Azure | Creates |
| --- | --- | --- | --- | --- |
| `bootstrap` | true | false | partial | Versioned state bucket, lock table, generated backend config |
| `infra-base` | true | true | true | Network with public/private subnets, Kubernetes cluster, DNS zone |
| `shared-resources` | true | false | false | PostgreSQL, DocumentDB, Valkey, RabbitMQ, Kafka — one instance each, shared by every product in the environment |
| `br-consignado-gw` | true | false | false | PostgreSQL, Valkey |
| `br-sfn` | true | false | false | PostgreSQL, Valkey, RabbitMQ, Kafka, S3 |
| `br-sisbajud` | true | false | false | PostgreSQL, Valkey, Kafka |
| `fetcher` | true | false | false | DocumentDB, Valkey, RabbitMQ, S3 |
| `flowker` | true | false | false | DocumentDB, Valkey |
| `matcher` | true | false | false | PostgreSQL, Valkey, RabbitMQ |
| `midaz` | true | false | false | PostgreSQL, DocumentDB, Valkey, RabbitMQ |
| `notifications` | true | false | false | PostgreSQL, Valkey, RabbitMQ |
| `plugin-access-manager` | true | false | false | PostgreSQL, Valkey |
| `plugin-bc-correios` | true | false | false | PostgreSQL, Valkey, RabbitMQ, S3 |
| `plugin-br-bank-transfer` | true | false | false | PostgreSQL, DocumentDB, Valkey, RabbitMQ |
| `plugin-br-payments` | true | false | false | PostgreSQL |
| `plugin-br-pix-direct-jd` | true | false | false | PostgreSQL |
| `plugin-br-pix-indirect-btg` | true | false | false | PostgreSQL, DocumentDB, Valkey |
| `plugin-br-pix-jd` | true | false | false | PostgreSQL |
| `plugin-br-pix-switch` | true | false | false | PostgreSQL, DocumentDB, Valkey, RabbitMQ |
| `plugin-fees` | true | false | false | DocumentDB, Valkey, Kafka |
| `product-console` | true | false | false | DocumentDB |
| `reporter` | true | false | false | DocumentDB, Valkey, RabbitMQ, S3 |
| `tracer` | true | false | false | PostgreSQL, Valkey |
| `underwriter` | true | false | false | PostgreSQL, Valkey |

On AWS: PostgreSQL is RDS, DocumentDB is Amazon DocumentDB, Valkey is ElastiCache,
RabbitMQ is AmazonMQ, Kafka is MSK. Each product datastore can be **dedicated** or
resolve the **shared** tier — except S3, which is never shared.

Azure `bootstrap` is partial: `base-resources` creates the storage account for state. Azure
locks state with a blob lease, so there is no lock table. On GCP you create the bucket
yourself, shown below.

**GCP and Azure have no per-product stacks.** They carry generic `cloud-sql`,
`valkey`, `database`, `redis` and `cosmosdb` roots, written for a single deployment and
hardcoded to Midaz. There is no product-scoped root and no shared/dedicated switch, so
the products read false rather than claiming a parity that does not exist.

---

# AWS

## 1. Install lerian-infra

Requires `terraform` >= 1.10.0, `aws`, and `git` on your `PATH` — the CLI shells out to
all three and checks for them before doing anything. You also need `kubectl` for the
step after the cluster exists; the CLI never calls it.

```bash
curl -fsSL https://raw.githubusercontent.com/LerianStudio/lerian-terraform-foundation/main/scripts/install.sh | sh
```

The script detects your platform, downloads the matching release, **verifies it against
the published checksums**, and installs into the first writable directory among
`~/.local/bin`, `~/bin` and `/usr/local/bin`. It never calls `sudo`; if none of those is
writable it tells you what to run. Nothing is installed if the checksum does not match.

| Variable | Does |
| --- | --- |
| `LERIAN_INFRA_VERSION` | Install a specific tag instead of the latest, e.g. `v1.6.0`. |
| `INSTALL_DIR` | Install somewhere else. |

Prefer to do it by hand, or on Windows? Take the archive from the [releases
page](https://github.com/LerianStudio/lerian-terraform-foundation/releases) and verify
it yourself:

```bash
tar xzf lerian-infra_<version>_Darwin_arm64.tar.gz
sha256sum -c checksums.txt --ignore-missing
```

Then check it runs:

```bash
lerian-infra --version
```

## 2. Get the templates

The binary and the templates ship from the same tag, and the CLI fetches its own:

```bash
lerian-infra init --env dev --clone
```

That clones the matching tag into `~/lerian/lerian-terraform-foundation`. If you are
already inside a checkout of this repository there is nothing to do — the CLI finds it
by walking up from the working directory.

After upgrading the binary, move the checkout to match:

```bash
lerian-infra init --env dev --sync
```

Your `environments.conf` and `envs/*.tfvars` survive that: they are gitignored, and a
checkout does not touch untracked files.

## 3. Deploy an environment

Four commands, in this order. Each one must finish before the next.

```bash
# Write the configuration: which AWS account this environment lives in, and the
# tfvars of every stack you named. Touches no AWS resource.
lerian-infra init --env dev --targets bootstrap,infra-base,midaz

# State bucket and lock table. Once per environment, ever.
lerian-infra --env dev --target bootstrap --action apply

# VPC, then EKS.
lerian-infra --env dev --target infra-base --action apply

# The product's datastores.
lerian-infra --env dev --target midaz --action apply
```

`init` asks what it cannot discover — AWS profile, region, account — and every question
has a flag, so a pipeline never hits a prompt. It lists the profiles it found with the
account each one reaches, and detects your egress address for the cluster's API
allow-list.

Before every run the CLI verifies that the state bucket, the region and the live
credentials all agree on which account this environment is. There is no flag to bypass
it.

Useful along the way:

| Command | Does |
| --- | --- |
| `lerian-infra --list` | Every deployable target. No AWS call. |
| `lerian-infra --env dev --target all --dry-run` | The whole execution plan: order, state keys, account. No AWS call. |
| `lerian-infra --env dev --target midaz --action destroy` | Reverse order, one confirmation. |
| `lerian-infra --help` | The full flag reference. |

Once EKS is up, the CLI prints the `aws eks update-kubeconfig` command for your
cluster.

## 4. Hand off to Helm

```bash
lerian-infra --env dev --target midaz --action helm-values --format yaml \
  > midaz-dev-values.yaml
```

This reads every stack of the product and merges their outputs into one values
document, keyed by the chart's own components, ready for `helm install -f`. No
credential is in it: it carries `secret_arn` and `secret_name`, while the passwords
stay in AWS Secrets Manager.

The charts are at **[LerianStudio/helm](https://github.com/LerianStudio/helm)**.

---

# GCP and Azure

These use the pre-v2 flat layout: one `midaz.tfvars` per component directory, and an
interactive script. Requires `terraform` plus `gcloud` or `az`.

## 1. Create the state bucket

**GCP:**

```bash
gsutil mb -p PROJECT_ID -l REGION gs://BUCKET_NAME
gsutil versioning set on gs://BUCKET_NAME
```

**Azure:**

```bash
az group create --name RESOURCE_GROUP --location LOCATION
az storage account create --name STORAGE_ACCOUNT --resource-group RESOURCE_GROUP \
  --location LOCATION --sku Standard_LRS
az storage container create --name CONTAINER --account-name STORAGE_ACCOUNT
```

## 2. Configure

Each component keeps its own `backend.tf` and `midaz.tfvars`, both edited by hand:

```bash
cd examples/<gcp|azure>/<component>
$EDITOR backend.tf                        # bucket, prefix, credentials
cp midaz.tfvars-example midaz.tfvars
$EDITOR midaz.tfvars
```

The script refuses to deploy a component whose `backend.tf` still holds a
`<PUT-YOUR-...>` placeholder.

## 3. Deploy

```bash
./deploy-legacy.sh
```

Interactive: pick the provider, pick deploy or destroy, pick the components. Order
matters — network first, then the cluster, then the datastores.

| Component | GCP | Azure |
| --- | --- | --- |
| network | `vpc` | `network` |
| dns | `cloud-dns` | `dns` |
| kubernetes | `gke` | `aks` |
| database | `cloud-sql` | `database` |
| valkey | `valkey` | `redis` |
| mongodb | — | `cosmosdb` |

Take the endpoints from `terraform output` and wire them into the charts at
**[LerianStudio/helm](https://github.com/LerianStudio/helm)**.

---

# Important information

Read this before a production deployment.

- **Instance sizing is your responsibility.** The classes in the example `.tfvars` are
  starting points, not a capacity plan. The prd examples step up to multi-AZ and larger
  classes, but only you know your transaction volume, peak concurrency and growth.
  Review instance classes, storage, IOPS and connection limits before applying. Lerian
  is not responsible for performance or cost resulting from those choices.

- **Clusters are created with a public API endpoint, restricted by CIDR.** That is the
  default for dev and staging. `lerian-infra init --api-cidr auto` fills the allow-list
  with your egress address. For a private endpoint, set
  `cluster_endpoint_private_access = true` and `cluster_endpoint_public_access = false`;
  the allow-list then has no effect.

- **A VPN and a private cluster are yours to build and operate.** These templates create
  neither. If you go that route: the VPN server needs a Network ACL and a security group
  rule to reach the database subnets on the service port, and a security group rule on
  the control plane to reach the Kubernetes API. Note that `lerian-infra` itself must
  then run from inside the network.

- **There is no default StorageClass.** The `aws-ebs-csi-driver` add-on installs the
  driver, not a StorageClass, and the `gp2` class EKS ships is not marked default. A PVC
  without an explicit `storageClassName` stays `Pending`. Create a default `gp3` class
  with `volumeBindingMode: WaitForFirstConsumer` before installing anything that needs a
  volume — `Immediate` binds the volume to an AZ before the scheduler picks a node.

- **EBS cannot serve `ReadWriteMany`.** That needs the `aws-efs-csi-driver` add-on,
  which these templates do not install.

- **Cluster add-ons beyond the basics are yours.** `infra-base/eks` installs `coredns`,
  `kube-proxy`, `vpc-cni`, `metrics-server` and `aws-ebs-csi-driver`. Cluster
  Autoscaler, the [AWS Load Balancer
  Controller](https://artifacthub.io/packages/helm/aws/aws-load-balancer-controller) and
  an [ingress
  controller](https://artifacthub.io/packages/helm/ingress-nginx/ingress-nginx) are
  installed by you. The IRSA roles for the first two already exist in
  `examples/aws/infra-base/eks/iam.tf`, and the subnets are already tagged for LB
  discovery — point the service accounts at the role ARNs rather than creating your own.

- **AmazonMQ speaks AMQPS only.** Any component connecting to it needs
  `RABBITMQ_URI: "amqps"`. `--action helm-values` emits that already.

- **State is segregated per environment.** dev, stg and prd each get their own bucket
  (`lerian-tfstate-{env}-{account_id}`) and lock table, so a dev apply cannot reach prd
  state even when all three live in the same AWS account.

- **Secrets never leave the cloud.** Passwords and auth tokens are generated by Terraform
  into AWS Secrets Manager and never read back. Outputs carry references, so the whole
  Helm handoff can be printed or logged safely. Saved plan files are a different matter
  — they can embed values read from state, and `lerian-infra` writes them into a `0700`
  directory for that reason. Do not archive them.

- **Bringing your own pipeline?** `lerian-infra` is built to run from one: every decision
  is a flag, and outside a terminal a missing one is an error naming the flag rather
  than a guess. Two things to know: `--auto-approve` skips the confirmation but never
  the account guard, and it does not authorise a clone — pin the templates in your image
  or point at them with `$LERIAN_TF_REPO`. If you would rather drive Terraform directly,
  copy the roots into your own repository; note that the Helm handoff has no equivalent
  outside the CLI.

# Reference

## Repository layout

```
cmd/lerian-infra/          the CLI
pkg/infra/                 the library behind it, importable
deploy-legacy.sh           GCP and Azure, interactive
examples/
  aws/                     v2 layout: environment-scoped, one state per stack
    environments.conf      env -> AWS account map (gitignored, written by init)
    backend/<env>.hcl      generated by bootstrap
    bootstrap/
    infra-base/{vpc,eks}
    products/<product>/<engine>/
    _modules/              shared datastore modules
  gcp/, azure/             v1 layout: one directory per resource
```

Every root under `examples/aws/` carries a README describing what it creates, what it
costs and how it is configured. Start there for anything this page does not cover.

## Contributing

Install the git hooks before your first commit — they enforce the commit conventions
this repository releases from:

```bash
make hooks
```

Branch from `develop`, commit with [conventional
commits](https://www.conventionalcommits.org/), and open a PR against `develop`. See
[CONTRIBUTING.md](CONTRIBUTING.md).

## Security

Report vulnerabilities per [SECURITY.md](SECURITY.md) — not through public issues.

## License

Apache 2.0. See [LICENSE](LICENSE).

## Support

Check the README of the root you are deploying, then search
[issues](https://github.com/LerianStudio/lerian-terraform-foundation/issues).
