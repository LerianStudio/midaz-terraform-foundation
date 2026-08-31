################################################################################
# product-network — the shared network resolution of a product root stack
#
# PURE LOOKUP MODULE. It creates no AWS resource: no VPC, no subnet, no security
# group. It answers three questions every products/{product}/*
# root stack asks identically, and would otherwise answer by copying ~70 lines of
# data sources and locals into each service directory:
#
#   1. which VPC is this product deployed into, and what are its private subnets
#   2. which sources may reach this product's datastores (the ingress allow list)
#   3. what are the derived cross-stack names — VPC and EKS cluster
#
# Answer (2) is the reason it exists. The datastore modules resolve their own
# VPC and subnets for the resources they PLACE, but they cannot decide who
# is allowed to reach them: that is a fact about the EKS cluster, and it belongs
# to the product stack.
#
# Everything is derived from var.environment. In the normal case a caller sets
# `enabled` and `environment` and nothing else.
################################################################################

locals {
  # Cross-stack identifiers. Both are the strings the infra-base stacks produce
  # for this environment, so the normal case is that neither override variable
  # is set.
  vpc_name         = var.vpc_name != "" ? var.vpc_name : "lerian-${var.environment}-vpc"
  eks_cluster_name = var.eks_cluster_name != "" ? var.eks_cluster_name : "lerian-${var.environment}-eks"

  lookup_private_subnets = var.enabled && var.allow_private_subnet_cidr_ingress
  lookup_eks_node_sg     = var.enabled && var.eks_node_security_group_lookup_enabled

  ##############################################################################
  # Ingress allow lists
  #
  # sort() makes the lists deterministic. The datastore modules key their ingress
  # rules on the values, so ordering cannot move a rule between addresses, but a
  # stable order keeps plan output readable.
  ##############################################################################
  private_subnet_cidrs        = sort([for subnet in data.aws_subnet.private : subnet.cidr_block])
  eks_node_security_group_ids = sort(try(data.aws_security_groups.eks_nodes[0].ids, []))

  ingress_security_group_ids = sort(distinct(concat(
    var.allowed_security_group_ids,
    local.eks_node_security_group_ids,
  )))

  ingress_cidr_blocks = sort(distinct(concat(
    var.allowed_cidr_blocks,
    local.private_subnet_cidrs,
  )))
}

################################################################################
# Guardrail
#
# A `check` block, not a `precondition`: this describes a state that is
# legitimate during a first apply and only becomes a bug if it persists. A hard
# failure here would make the documented deploy order un-appliable.
#
# It lives HERE rather than in each calling root so the message is written once.
# check blocks are evaluated inside child modules exactly as they are in a root,
# and their warnings surface in the caller's plan output with this module's
# address.
#
# The "nothing can reach this datastore at all" case is NOT asserted here — each
# datastore module already carries check "ingress_is_reachable" for it, and two
# checks asserting the same thing would report the same problem twice.
################################################################################

check "eks_node_security_group_resolved" {
  assert {
    condition = (
      !local.lookup_eks_node_sg
      || length(local.eks_node_security_group_ids) > 0
    )
    error_message = <<-EOT
      The EKS node security group lookup for tag:Name = "${local.eks_cluster_name}-node"
      in VPC ${local.vpc_name} returned nothing. Either infra-base/eks has not been
      applied yet (expected before the cluster exists — re-apply this stack afterwards
      to pick the group up), or var.eks_cluster_name does not match the real cluster
      name. Ingress currently comes from allowed_cidr_blocks and the private subnet
      CIDRs only. Set eks_node_security_group_lookup_enabled = false to silence this on
      a deployment that has no EKS cluster at all.
    EOT
  }
}
