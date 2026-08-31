################################################################################
# Lookups
#
# Every lookup is gated on var.enabled, which a product root stack sets to
# `var.mode == "dedicated"`. In shared mode this module resolves nothing and does
# not even require the VPC to exist — the datastore modules resolve the shared
# endpoint from DNS and the shared credentials from Secrets Manager, with no AWS
# API call of their own.
#
# Each datastore module performs its OWN VPC, subnet and zone lookups for the
# resources it places. The ones here exist for a single purpose those modules
# cannot serve: computing the ingress allow list the product stack has to hand
# them, because "which sources may reach this product's datastores" is a decision
# about the EKS cluster, not about the datastore being protected.
################################################################################

data "aws_vpc" "selected" {
  count = var.enabled ? 1 : 0

  filter {
    name   = "tag:Name"
    values = [local.vpc_name]
  }
}

################################################################################
# Private subnet CIDRs — the default ingress path
#
# Type=private is where the EKS nodes and the interface VPC endpoints live. This
# is deliberately NOT the whole VPC CIDR: the public subnets have no business
# reaching a datastore, and the datastore modules' own VPC-CIDR fallback would
# include them.
#
# aws_subnets returns ids only, so the CIDR of each one needs the singular data
# source. for_each rather than count, so the set is keyed by subnet id and adding
# an AZ does not renumber the others.
################################################################################

data "aws_subnets" "private" {
  count = local.lookup_private_subnets ? 1 : 0

  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.selected[0].id]
  }

  tags = {
    Type = var.subnet_tag_type
  }
}

data "aws_subnet" "private" {
  for_each = local.lookup_private_subnets ? toset(data.aws_subnets.private[0].ids) : toset([])

  id = each.value
}

################################################################################
# EKS node security group
#
# PLURAL data source on purpose. data "aws_security_group" (singular) FAILS the
# plan when nothing matches, which would make every product stack un-appliable
# until infra-base/eks exists. data "aws_security_groups" returns an empty list
# instead, so the plan succeeds before the cluster exists and starts producing
# an ingress rule on the first apply after it does. The check block in main.tf
# turns that transition into a visible warning rather than a silent gap.
#
# Match is by tag:Name = "{cluster}-node", which terraform-aws-modules/eks sets
# verbatim on the node security group. The SG's own `name` attribute carries a
# generated suffix because the module uses name_prefix, so the tag is the only
# stable handle — filtering on group-name would not match.
################################################################################

data "aws_security_groups" "eks_nodes" {
  count = local.lookup_eks_node_sg ? 1 : 0

  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.selected[0].id]
  }

  tags = {
    Name = "${local.eks_cluster_name}-node"
  }
}
