################################################################################
# products/network/vpc-peering-accepter — the application-stack side of a
# peering the control plane requested
#
# The control plane (Terraform environment `dev`, VPC 10.59.0.0/16) lives in one
# AWS account; the two application stacks (`stg` 10.61.0.0/16 and `prd`
# 10.60.0.0/16) live in another. The tenant-manager runs in the control plane and
# provisions datastores that live in the stacks, so the two VPCs have to reach
# each other on private addresses.
#
# A VPC peering connection is TWO resources in TWO accounts:
# products/network/vpc-peering-requester creates the request over there, this
# root accepts it over here. There is no single apply that does both — the
# account guard in lerian-infra has no bypass, and a provider alias assuming a
# role in the other account would put one account's credentials in the other
# account's state. So:
#
#   1. apply the requester in the control-plane account -> `terraform output pcx_ids`
#   2. write each id into pcx_id in the accepter tfvars of the matching stack
#   3. apply THIS root there, once per stack
#
# Both steps are IaC. Nothing here is clicked.
#
# APPLIED TWICE, ONE ENVIRONMENT AT A TIME. Two stacks share this account, so
# this one directory is applied as `stg` and as `prd`, into two separate states
# (see backend.tf). Every input is singular for that reason: each apply accepts
# exactly one peering — the one to the control plane. There is no
# staging <-> production peering to accept, and no way to express one here, which
# is what keeps a compromise or a misrouted packet in staging away from
# production money paths.
#
# WHY IT LIVES UNDER products/ WHEN IT IS NOT A PRODUCT. lerian-infra discovers
# roots by walking products/*/* and nothing else, and its infra-base stage is
# hardcoded to exactly vpc and eks (pkg/infra/discover.go:36-78, :128-153). A
# root at infra-base/vpc-peering would be invisible to the CLI: no ordering, no
# account guard, no state key. Precedent: products/lerian-platform/dns.
#
# NO DNS RESOLUTION OVER THE PEERING. There is no accepter options block
# enabling remote DNS resolution: the control plane is reached through a PUBLIC
# hosted zone that answers with the private ALB address
# (tm-int.devops.consignado.lerian.dev), so cross-VPC private DNS is not part of
# the design.
################################################################################

module "naming" {
  source = "../../../_modules/naming"

  product     = var.product
  environment = var.environment
  component   = "peering"
  extra_tags  = var.extra_tags
}

################################################################################
# Local VPC resolution — _modules/product-network
#
# This root does not need the local VPC id: the accepter resource is addressed by
# peering id, not by VPC. What it needs is the local VPC's CIDR, and only for the
# overlap guard below — which is reason enough, because without the module there
# is nothing to compare var.peer_cidr against and the guard could not exist.
# Resolution is by tag:Name = "lerian-{environment}-vpc", so there is no new
# input to keep in sync with infra-base/vpc.
#
# The module's two ingress lookups are turned OFF. They exist to compute the
# allow list a datastore's security group needs, and this root creates no
# datastore and no security group: leaving them on would make three AWS calls
# whose results nothing reads, and would arm check "eks_node_security_group_resolved"
# with a warning about an EKS cluster this root has no opinion about.
################################################################################

module "network" {
  source = "../../../_modules/product-network"

  enabled     = true
  environment = var.environment

  allow_private_subnet_cidr_ingress      = false
  eks_node_security_group_lookup_enabled = false
}

locals {
  ##############################################################################
  # CIDR overlap test — same arithmetic as the requester root
  #
  # Two CIDR blocks are either disjoint or nested — there is no partial overlap —
  # so they intersect exactly when their network addresses agree at the SHORTER
  # of the two prefix lengths. cidrhost("{network}/{shorter}", 0) is that
  # comparison: the inner call normalises each block to its own network address,
  # the outer one re-masks it to the shorter prefix.
  #
  # Terraform 1.15 has no cidrcontains/cidroverlap function, and comparing first
  # and last addresses as strings would compare them lexicographically, where
  # "10.9.0.0" sorts after "10.10.0.0". This form needs no numeric conversion of
  # addresses at all.
  ##############################################################################
  local_cidr   = module.network.vpc_cidr_block
  local_prefix = tonumber(split("/", local.local_cidr)[1])
  peer_prefix  = tonumber(split("/", var.peer_cidr)[1])

  shared_prefix = min(local.local_prefix, local.peer_prefix)

  peer_overlaps_local_vpc = (
    cidrhost("${cidrhost(local.local_cidr, 0)}/${local.shared_prefix}", 0)
    ==
    cidrhost("${cidrhost(var.peer_cidr, 0)}/${local.shared_prefix}", 0)
  )
}

################################################################################
# The acceptance
#
# auto_accept = true here is the mirror image of auto_accept = false on the
# requester: accepting is an action taken by the OWNER of the peer VPC, which is
# this account. This is the only resource in the estate that completes a
# connection another account opened.
#
# This resource ADOPTS a connection it does not own the lifecycle of. Destroying
# it does not delete the peering — it removes the acceptance from state and the
# connection returns to the requester's control. The routes below go with it,
# which is the part that actually stops traffic.
################################################################################

resource "aws_vpc_peering_connection_accepter" "this" {
  vpc_peering_connection_id = var.pcx_id
  auto_accept               = true

  tags = merge(module.naming.tags, { Name = module.naming.name })
}

################################################################################
# Return routes to the control plane
#
# The acceptance alone carries no traffic. Routing is per direction: the
# requester's routes send packets from the control plane into this VPC, and these
# send the replies back. Without them the connection is ACTIVE and every
# tenant-manager call into this stack times out with nothing logged.
#
# vpc_peering_connection_id reads the ACCEPTER's attribute rather than
# var.pcx_id, even though the two values are identical. The value is not the
# point — the dependency edge is: routing a pending-acceptance connection fails,
# so the graph has to order every route after the acceptance, and it only knows
# to do that if the route refers to the resource.
################################################################################

resource "aws_route" "to_control_plane" {
  for_each = toset(var.route_table_ids)

  route_table_id            = each.value
  destination_cidr_block    = var.peer_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.this.vpc_peering_connection_id

  lifecycle {
    # A route whose destination overlaps the LOCAL VPC CIDR is the expensive
    # digit slip on this estate. The control plane is 10.59.0.0/16, production is
    # 10.60.0.0/16 and staging is 10.61.0.0/16 — one character apart. Writing
    # 10.60.0.0/16 into peer_cidr while applying `prd` does not fail: AWS accepts
    # the route, and from then on the more specific local route wins for some
    # destinations while this one hijacks the rest of the VPC's own address
    # space. Nothing is logged; it surfaces as intermittently unreachable
    # datastores inside the account.
    #
    # The guard lives on the route and not on the accepter because the route is
    # what carries the bad value. It is reached on every apply: route_table_ids
    # is validated non-empty, so at least one instance of this resource always
    # exists to evaluate it.
    #
    # Evaluated against a data source, so on a plan without credentials the local
    # CIDR is unknown and Terraform defers the check to apply. It still runs
    # before anything is created.
    precondition {
      condition     = !local.peer_overlaps_local_vpc
      error_message = "peer_cidr is ${var.peer_cidr}, which overlaps the local VPC CIDR of environment ${var.environment}. A route to a block that contains this VPC's own addresses is accepted by AWS and then hijacks local traffic — the failure surfaces as datastores in this account becoming intermittently unreachable, with nothing logged. peer_cidr must be the CONTROL PLANE block (10.59.0.0/16), not this stack's own (staging 10.61.0.0/16, production 10.60.0.0/16); fix the tfvars rather than this guard."
    }
  }
}
