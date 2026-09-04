################################################################################
# products/network/vpc-peering-requester — the control-plane side of the two
# peerings
#
# The control plane (Terraform environment `dev`, VPC 10.59.0.0/16) lives in one
# AWS account; the two application stacks (`stg` 10.61.0.0/16 and `prd`
# 10.60.0.0/16) live in another. The tenant-manager runs in the control plane and
# provisions datastores that live in the stacks, so the two VPCs have to reach
# each other on private addresses.
#
# A VPC peering connection is TWO resources in TWO accounts: the requester here,
# the accepter in products/network/vpc-peering-accepter. There is no single apply
# that does both — the account guard in lerian-infra has no bypass, and a
# provider alias assuming a role in the other account would put one account's
# credentials in the other account's state. So:
#
#   1. apply this root in the control-plane account -> `terraform output pcx_ids`
#   2. write each id into the accepter tfvars of the stack account
#   3. apply the accepter there
#
# Both steps are IaC. Nothing here is clicked.
#
# WHY IT LIVES UNDER products/ WHEN IT IS NOT A PRODUCT. lerian-infra discovers
# roots by walking products/*/* and nothing else, and its infra-base stage is
# hardcoded to exactly vpc and eks (pkg/infra/discover.go:36-78, :128-153). A
# root at infra-base/vpc-peering would be invisible to the CLI: no ordering, no
# account guard, no state key. Precedent: products/lerian-platform/dns.
#
# NO staging <-> production PEERING. This root peers the control plane with each
# stack and the stacks are never peered with each other, which is what keeps a
# compromise or a misrouted packet in staging away from production money paths.
# Adding a third entry to var.peers pointing one stack at the other would break
# that by configuration alone, which is why the peer map is written per account
# in reviewable tfvars rather than derived.
#
# NO DNS RESOLUTION OVER THE PEERING. There is no `requester`/`accepter` options
# block enabling remote DNS resolution: the control plane is reached by a PUBLIC
# hosted zone that answers with the private ALB address
# (tm-int.devops.consignado.lerian.dev), so cross-VPC private DNS is not part of
# the design. No `peer_region` either — both accounts are in the same region.
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
# The only thing this root needs from the network module is the LOCAL VPC: its id
# (the requester side of the peering) and its CIDR (what the overlap guard below
# compares against). Both are resolved by tag:Name = "lerian-{environment}-vpc",
# so there is no new input to keep in sync with infra-base/vpc.
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
  # CIDR overlap test
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

  shared_prefix = {
    for key, peer in var.peers :
    key => min(local.local_prefix, tonumber(split("/", peer.cidr)[1]))
  }

  peer_overlaps_local_vpc = {
    for key, peer in var.peers :
    key => (
      cidrhost("${cidrhost(local.local_cidr, 0)}/${local.shared_prefix[key]}", 0)
      ==
      cidrhost("${cidrhost(peer.cidr, 0)}/${local.shared_prefix[key]}", 0)
    )
  }

  ##############################################################################
  # One route per (peer, route table) pair
  #
  # setproduct rather than nested for_each, because a resource takes one for_each
  # and the two dimensions are independent: N peers reachable from M local route
  # tables is N*M routes. The key is "{peer}|{route table}" so that adding a
  # route table never renumbers the routes of another peer — "|" cannot appear in
  # either a peer key or an rtb id, so the composite key is unambiguous.
  ##############################################################################
  peer_routes = {
    for pair in setproduct(keys(var.peers), var.route_table_ids) :
    "${pair[0]}|${pair[1]}" => {
      peer           = pair[0]
      route_table_id = pair[1]
      cidr           = var.peers[pair[0]].cidr
    }
  }
}

################################################################################
# The peering requests
#
# auto_accept = false is not a preference, it is arithmetic: auto-accept only
# works when both VPCs are in the same account, and the whole point of this root
# is that they are not. The accepter root does the accepting.
################################################################################

resource "aws_vpc_peering_connection" "this" {
  for_each = var.peers

  vpc_id        = module.network.vpc_id
  peer_vpc_id   = each.value.vpc_id
  peer_owner_id = each.value.account_id
  auto_accept   = false

  tags = merge(module.naming.tags, { Name = "${module.naming.name}-${each.key}" })

  lifecycle {
    # AWS REFUSES a peering between overlapping CIDRs: "you cannot create a VPC
    # peering connection between VPCs that have matching or overlapping IPv4 or
    # IPv6 CIDR blocks" (VPC Peering Guide, limitations). It refuses it LATE,
    # though. CreateVpcPeeringConnection returns an id, the request goes
    # initiating-request -> failed, and the provider only waits for
    # pending-acceptance/active, so the apply aborts partway with
    #
    #   waiting for EC2 VPC Peering Connection (pcx-...) create:
    #   unexpected state 'failed'
    #
    # after that dead id has already been written to state, and a failed
    # connection can be neither accepted nor rejected while it lingers.
    #
    # That is all this guard buys, and it is enough: the same refusal at plan
    # time, before any resource is created, naming the peer key, both CIDRs and
    # the blocks this estate actually uses — instead of a state-machine string
    # that names neither the tfvars nor the value that was wrong.
    #
    # The guard is evaluated against a data source, so on a plan without
    # credentials the local CIDR is unknown and Terraform defers the check to
    # apply. It still runs before anything is created.
    precondition {
      condition     = !local.peer_overlaps_local_vpc[each.key]
      error_message = "Peer \"${each.key}\" has CIDR ${each.value.cidr}, which overlaps the local VPC CIDR of environment ${var.environment}. AWS refuses a peering between overlapping CIDRs: the request would land in state \"failed\" and the apply would abort with \"unexpected state 'failed'\", after a dead connection id had already been written to state. The two estates must use disjoint blocks (control plane 10.59.0.0/16, staging 10.61.0.0/16, production 10.60.0.0/16); fix the CIDR in the tfvars rather than this guard."
    }
  }
}

################################################################################
# The connections, read back from the API
#
# The same data source products/network/vpc-peering-accepter uses on the other
# side, for the same reason: peers[*].cidr is a hand-written claim about a VPC in
# another account, and no data source in THIS account can read that VPC. Reading
# the CONNECTION can — once it exists, AWS reports the accepter's block on it.
#
# It reports it late. "CIDR block information is only returned when describing an
# active VPC peering connection" (AWS CLI reference, describe-vpc-peering-
# connections, AccepterVpcInfo), so between this apply and the acceptance over
# there, peer_cidr_block is empty and there is nothing to compare. That is the
# only window, and it closes for good on the first plan after acceptance.
################################################################################

data "aws_vpc_peering_connection" "this" {
  for_each = aws_vpc_peering_connection.this

  id = each.value.id
}

################################################################################
# Local routes to each peer
#
# The peering connection alone carries no traffic. Without these routes the
# connection is ACTIVE and useless, which is the single most common way a
# working peering looks broken.
################################################################################

resource "aws_route" "to_peer" {
  for_each = local.peer_routes

  route_table_id            = each.value.route_table_id
  destination_cidr_block    = each.value.cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.this[each.value.peer].id

  lifecycle {
    # DECLARED vs REAL, and it is the requester-side mirror of the accepter's
    # cidr_block provenance check. The overlap guard above only proves the
    # declared block does not collide with this VPC; a declared block that is
    # simply WRONG about the peer VPC — 10.61.0.0/16 written for a VPC that is
    # really 10.62.0.0/16 — collides with nothing and applies cleanly. The route
    # then sends that traffic into a peering whose other end does not own the
    # addresses, and from inside this VPC the timeouts look like a firewall.
    #
    # SILENT ON THE FIRST APPLY, deliberately, and it cannot be otherwise: the
    # connection is still pending-acceptance, and AWS returns no accepter CIDR
    # for one — "CIDR block information is only returned when describing an
    # active VPC peering connection" (AWS CLI reference, describe-vpc-peering-
    # connections, AccepterVpcInfo). Nothing is lost by letting the route through
    # then: "You can add a route for a VPC peering connection that's in the
    # pending-acceptance state. However, the route has a state of blackhole, and
    # has no effect until the VPC peering connection is in the active state" (VPC
    # Peering Guide, "Update your route tables for a VPC peering connection").
    # The route carries nothing until the other account accepts, which is exactly
    # when the API starts answering and this check starts running — on every plan
    # from then on, including the ones that only meant to add a route table.
    precondition {
      # NOT coalesce(peer_cidr_block, ""): coalesce returns the first argument
      # that is neither null NOR an empty string, so with an empty block it has
      # no argument left to return and fails the plan — in exactly the
      # pending-acceptance case this branch exists to wave through. The null test
      # is load-bearing too: null == "" is null, not false, and a condition that
      # evaluates to null is an error rather than a pass.
      condition = (
        data.aws_vpc_peering_connection.this[each.value.peer].peer_cidr_block == null ||
        data.aws_vpc_peering_connection.this[each.value.peer].peer_cidr_block == "" ||
        data.aws_vpc_peering_connection.this[each.value.peer].peer_cidr_block == each.value.cidr
      )
      error_message = "Peer \"${each.value.peer}\" declares CIDR ${each.value.cidr} in peers, but the accepter VPC on the other end of this connection really has ${data.aws_vpc_peering_connection.this[each.value.peer].peer_cidr_block} — the API reports it now that the connection is active. This route sends ${each.value.cidr} into a peering whose far end does not own that block, so the traffic leaves and nothing answers. Fix peers[\"${each.value.peer}\"].cidr in the tfvars to the block that VPC actually has, rather than this guard."
    }
  }
}
