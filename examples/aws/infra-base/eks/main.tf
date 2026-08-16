################################################################################
# Naming
#
# Cluster name = module.naming.name = {product}-{environment}-eks.
#
# CONTRACT WITH infra-base/vpc: that stack tags its subnets with
# kubernetes.io/cluster/lerian-{environment}-eks. Both names are derived from the
# same {product}-{environment}-{component} rule, so they must be kept in sync —
# changing `product` here without changing it there breaks subnet auto-discovery
# for the AWS Load Balancer Controller and for EKS itself.
################################################################################

module "naming" {
  source = "../../_modules/naming"

  product     = var.product
  environment = var.environment
  component   = "eks"
  extra_tags  = var.extra_tags
}

locals {
  # VPC produced by infra-base/vpc, resolved by tag:Name.
  vpc_name = var.vpc_name != "" ? var.vpc_name : "lerian-${var.environment}-vpc"

  # ASG tags the Cluster Autoscaler needs for node group auto-discovery. Keyed on
  # module.naming.name rather than module.eks.cluster_name to avoid a cycle
  # (these tags are an input to the EKS module).
  autoscaler_discovery_tags = var.create_autoscaler_role ? {
    "k8s.io/cluster-autoscaler/enabled"               = "true"
    "k8s.io/cluster-autoscaler/${module.naming.name}" = "owned"
  } : {}

  # Every node group and its IAM role are named {cluster-name}-{map key}, with
  # name prefixes disabled so the name is fully deterministic. That name carries
  # the environment, which is what allows dev/stg/prd in one AWS account.
  eks_managed_node_groups = {
    for key, ng in var.node_groups : key => {
      name                     = "${module.naming.name}-${key}"
      use_name_prefix          = false
      iam_role_name            = "${module.naming.name}-${key}"
      iam_role_use_name_prefix = false

      min_size       = ng.min_size
      max_size       = ng.max_size
      desired_size   = ng.desired_size
      instance_types = ng.instance_types
      capacity_type  = ng.capacity_type
      ami_type       = ng.ami_type

      attach_cluster_primary_security_group = ng.attach_cluster_primary_security_group
      create_security_group                 = ng.create_security_group

      # Root volume. volume_size = null keeps the AMI default. Assumes an
      # Amazon Linux root device; Bottlerocket splits os/data volumes and needs
      # its own launch template, which this stack does not model.
      block_device_mappings = {
        root = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = ng.disk_size
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }

      labels = merge({
        Environment = var.environment
        GithubRepo  = "lerian-terraform-foundation"
      }, ng.labels)

      taints = ng.taints

      # IMDSv2 required, hop limit 2 so pods on the host network cannot reach
      # the node credentials through IMDSv1.
      metadata_options = {
        http_tokens                 = "required"
        http_put_response_hop_limit = 2
      }

      tags = merge(module.naming.tags, local.autoscaler_discovery_tags, ng.tags)
    }
  }
}

# A public API endpoint with no CIDR restriction means AWS applies 0.0.0.0/0.
check "api_endpoint_exposure" {
  assert {
    condition     = !var.cluster_endpoint_public_access || length(var.allowed_api_access_cidrs) > 0
    error_message = "cluster_endpoint_public_access is true with an empty allowed_api_access_cidrs: the Kubernetes API would be reachable from 0.0.0.0/0."
  }

  # The explicit twin of the assert above. ["0.0.0.0/0"] produces exactly the
  # exposure an empty list produces, and the length() assert cannot see it.
  #
  # A second assert on the existing check rather than a precondition, on purpose.
  # AWS accepts 0.0.0.0/0 here, so unlike the reserved ranges guarded below there
  # is no apply that cannot succeed - this is a judgement about exposure, and an
  # operator bootstrapping a cluster from a dynamic address has a legitimate
  # reason to open it for one apply and narrow it immediately after. Same
  # reasoning the rabbitmq-amazonmq module writes down for its ingress_is_reachable
  # check: worth shouting about, not worth making the stack un-appliable.
  assert {
    condition     = !var.cluster_endpoint_public_access || !contains(var.allowed_api_access_cidrs, "0.0.0.0/0")
    error_message = "allowed_api_access_cidrs contains 0.0.0.0/0: the Kubernetes API is reachable from the entire internet, the same exposure as leaving the list empty. Narrow it to your public egress address (curl -s https://checkip.amazonaws.com, then \"<that address>/32\"), or set cluster_endpoint_public_access = false and reach the API over the private endpoint."
  }
}

################################################################################
# Public API endpoint allow list - plan-time guards
#
# allowed_api_access_cidrs is handed straight to CreateCluster as
# publicAccessCidrs, and AWS validates it there:
#
#   InvalidParameterException: The following CIDRs are not allowed in
#   publicAccessCidrs: [198.51.100.10/32, 203.0.113.0/24]
#
# The EKS docs only say the list "cannot include reserved addresses" without
# enumerating them, and the rejection lands about a minute into an apply that has
# already created the KMS key, both IAM roles and the log group.
#
# The concrete footgun: the envs/*.tfvars-example files used to ship the RFC 5737
# documentation ranges (203.0.113.0/24, 198.51.100.10/32) as placeholders. That is
# the right way to write an example address in prose and the wrong way to write
# one in a file whose whole purpose is to be copied and applied - AWS refuses
# exactly those blocks. Anyone who copied the file and forgot to edit it got an
# apply-time AWS error instead of guidance.
#
# Same family of guard as the postgres-rds Performance Insights precondition and
# the mongodb-documentdb instance class one: convert an AWS-side rejection that
# only surfaces mid-apply into a plan-time error that carries the fix.
################################################################################

locals {
  # Blocks AWS refuses in publicAccessCidrs. Kept separate from the private
  # ranges below because the two failures need different advice.
  #
  # 0.0.0.0/0 is deliberately absent: AWS accepts it, so it is not a plan error.
  # It is handled as a warning by check "api_endpoint_exposure" above, next to the
  # empty-list case that produces the identical exposure.
  reserved_api_cidr_blocks = [
    "192.0.2.0/24",      # RFC 5737 TEST-NET-1 (documentation)
    "198.51.100.0/24",   # RFC 5737 TEST-NET-2 (documentation)
    "203.0.113.0/24",    # RFC 5737 TEST-NET-3 (documentation)
    "198.18.0.0/15",     # RFC 2544 benchmarking
    "0.0.0.0/8",         # RFC 1122 "this network"
    "127.0.0.0/8",       # RFC 1122 loopback
    "169.254.0.0/16",    # RFC 3927 link-local
    "192.0.0.0/24",      # RFC 6890 IETF protocol assignments
    "192.88.99.0/24",    # RFC 7526 6to4 relay anycast (deprecated)
    "224.0.0.0/4",       # RFC 5771 multicast
    "240.0.0.0/4",       # RFC 1112 reserved for future use
    "255.255.255.255/32" # RFC 8190 limited broadcast
  ]

  # Not necessarily refused by AWS, but never correct here. This list filters
  # traffic arriving at the PUBLIC endpoint, where the source address AWS matches
  # is always a public one, so a private or CGNAT entry matches nothing. The
  # failure mode is worse than an error: the operator believes the office is
  # allowlisted, every kubectl call times out, and the usual next move is to widen
  # the list to 0.0.0.0/0. In-VPC access belongs on the private endpoint
  # (cluster_endpoint_private_access), which this list does not govern.
  unroutable_api_cidr_blocks = [
    "10.0.0.0/8",     # RFC 1918 private
    "172.16.0.0/12",  # RFC 1918 private
    "192.168.0.0/16", # RFC 1918 private
    "100.64.0.0/10"   # RFC 6598 carrier-grade NAT
  ]

  # cidrnetmask() accepts IPv4 CIDRs only, so this single filter catches both
  # malformed strings - the "<PUT-YOUR-EGRESS-IP-HERE>/32" placeholder the
  # tfvars-example files now ship, or a bare address with no prefix - and IPv6
  # blocks, which EKS rejects on an IPv4 cluster with its own "invalid in
  # publicAccessCidrs" error. Splitting valid from invalid first also keeps the
  # scans below from calling cidrhost() on something it cannot parse.
  api_cidrs_valid     = [for c in var.allowed_api_access_cidrs : c if can(cidrnetmask(c))]
  api_cidrs_malformed = [for c in var.allowed_api_access_cidrs : c if !can(cidrnetmask(c))]

  # "Is c inside b": mask c's network address down to b's prefix length and
  # compare it with b's network address. Terraform has no built-in containment
  # operator, and this is exact for the case that matters.
  #
  # The prefix-length comparison is what keeps a supernet from matching a block it
  # merely contains - specifically 0.0.0.0/0, which must fall through to the check
  # above instead of tripping on 0.0.0.0/8 here.
  api_cidrs_reserved = [
    for c in local.api_cidrs_valid : c
    if anytrue([
      for b in local.reserved_api_cidr_blocks :
      tonumber(split("/", c)[1]) >= tonumber(split("/", b)[1]) &&
      cidrhost("${cidrhost(c, 0)}/${split("/", b)[1]}", 0) == cidrhost(b, 0)
    ])
  ]

  api_cidrs_unroutable = [
    for c in local.api_cidrs_valid : c
    if anytrue([
      for b in local.unroutable_api_cidr_blocks :
      tonumber(split("/", c)[1]) >= tonumber(split("/", b)[1]) &&
      cidrhost("${cidrhost(c, 0)}/${split("/", b)[1]}", 0) == cidrhost(b, 0)
    ])
  ]
}

# The value being guarded is an input of module.eks, and a module block cannot
# carry a lifecycle block - so the preconditions hang off a resource of their own.
# postgres-rds and mongodb-documentdb attach theirs directly to the resource they
# protect because in those modules one exists; here nothing local represents the
# cluster. terraform_data is the built-in no-op resource for exactly this, and
# input = the guarded list keeps the dependency visible rather than implied.
resource "terraform_data" "api_access_cidr_guard" {
  input = var.allowed_api_access_cidrs

  lifecycle {
    precondition {
      condition     = length(local.api_cidrs_malformed) == 0
      error_message = "allowed_api_access_cidrs contains entries that are not IPv4 CIDR blocks: ${join(", ", local.api_cidrs_malformed)}. Every entry must be IPv4 <address>/<prefix>; EKS rejects IPv6 blocks on an IPv4 cluster. If that is still the tfvars placeholder, replace it with your real public egress address: run 'curl -s https://checkip.amazonaws.com' and use \"<that address>/32\"."
    }

    precondition {
      condition     = length(local.api_cidrs_reserved) == 0
      error_message = "allowed_api_access_cidrs contains reserved ranges AWS refuses in publicAccessCidrs: ${join(", ", local.api_cidrs_reserved)}. CreateCluster fails with 'InvalidParameterException: The following CIDRs are not allowed in publicAccessCidrs' about a minute into the apply. 192.0.2.0/24, 198.51.100.0/24 and 203.0.113.0/24 are the RFC 5737 documentation blocks - correct in prose, never appliable. Replace them with your real public egress address: run 'curl -s https://checkip.amazonaws.com' and use \"<that address>/32\"."
    }

    precondition {
      condition     = length(local.api_cidrs_unroutable) == 0
      error_message = "allowed_api_access_cidrs contains private or CGNAT ranges: ${join(", ", local.api_cidrs_unroutable)}. This list only filters traffic arriving at the PUBLIC API endpoint, where the source address is always public, so these entries allow nobody while looking like they allow the office. For access from inside the VPC keep cluster_endpoint_private_access = true and use the private endpoint. For an office or VPN, allowlist its public egress address instead: run 'curl -s https://checkip.amazonaws.com' and use \"<that address>/32\"."
    }
  }
}

################################################################################
# EKS cluster
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = module.naming.name
  kubernetes_version = var.cluster_version

  # Access entries only, no aws-auth ConfigMap.
  authentication_mode = "API"

  endpoint_private_access      = var.cluster_endpoint_private_access
  endpoint_public_access       = var.cluster_endpoint_public_access
  endpoint_public_access_cidrs = var.allowed_api_access_cidrs

  enable_cluster_creator_admin_permissions = var.enable_cluster_creator_admin_permissions

  # IAM roles allowed into the cluster and the EKS access policy each one gets.
  access_entries = {
    admin = {
      kubernetes_groups = []
      principal_arn     = aws_iam_role.admin_role.arn

      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            namespaces = []
            type       = "cluster"
          }
        }
      }
    }
    developer = {
      kubernetes_groups = []
      principal_arn     = aws_iam_role.developer_role.arn

      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
          access_scope = {
            namespaces = []
            type       = "cluster"
          }
        }
      }
    }
  }

  # Envelope encryption of Kubernetes secrets with the CMK from kms.tf.
  # create_kms_key = false: the key is managed outside this module, otherwise the
  # module would create a second key and contend for the same alias.
  create_kms_key = false
  encryption_config = {
    provider_key_arn = module.eks_kms_key.key_arn
    resources        = ["secrets"]
  }

  # Control plane logging. The log group is /aws/eks/{cluster-name}/cluster, so
  # its name carries the environment through module.naming.
  enabled_log_types                      = var.enabled_log_types
  cloudwatch_log_group_retention_in_days = var.cloudwatch_log_group_retention_in_days

  # Cluster addons. Everything else (autoscaler, load balancer controller,
  # ingress, external-dns, cert-manager) is Helm/GitOps territory.
  addons = {
    coredns = {
      most_recent                 = true
      resolve_conflicts_on_create = "NONE"
    }
    kube-proxy = {
      most_recent                 = true
      resolve_conflicts_on_create = "NONE"
      before_compute              = true
    }
    vpc-cni = {
      most_recent                 = true
      resolve_conflicts_on_create = "NONE"
      before_compute              = true
    }
    metrics-server = {
      most_recent                 = true
      resolve_conflicts_on_create = "NONE"
    }
    aws-ebs-csi-driver = {
      most_recent                 = true
      resolve_conflicts_on_create = "NONE"
      service_account_role_arn    = module.ebs_csi_irsa_role.iam_role_arn
    }
  }

  # Existing VPC and its private subnets.
  vpc_id     = data.aws_vpc.selected.id
  subnet_ids = data.aws_subnets.selected.ids

  # Node-to-node traffic, ALB health checks into NodePort range, and egress.
  node_security_group_additional_rules = {
    ingress_self_all = {
      description = "Node to node all ports/protocols"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
    ingress_alb_health_check = {
      description = "Allow ALB to access NodePort services for health checks"
      protocol    = "tcp"
      from_port   = 1025
      to_port     = 65535
      type        = "ingress"
      cidr_blocks = [data.aws_vpc.selected.cidr_block]
    }
    egress_vpc = {
      description = "Allow outbound traffic to VPC CIDR"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "egress"
      cidr_blocks = [data.aws_vpc.selected.cidr_block]
    }
    egress_all = {
      description = "Allow outbound traffic to internet"
      protocol    = "tcp"
      from_port   = 443
      to_port     = 443
      type        = "egress"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  eks_managed_node_groups = local.eks_managed_node_groups

  tags = module.naming.tags
}
