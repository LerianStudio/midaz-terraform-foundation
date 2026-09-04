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
# AND THE ID THAT CROSSES IS CHECKED AGAINST WHERE IT CAME FROM. A peering id is
# an opaque handle: `auto_accept = true` accepts whatever pcx- the tfvars names,
# and any AWS account on earth can open a peering request to a VPC in this one.
# Accepting the wrong request and then routing var.peer_cidr into it points a
# 10.59.0.0/16 route at a stranger's VPC — from inside, indistinguishable from a
# working control plane. The three preconditions on the accepter below read the
# connection back from the API and refuse a request that is not the one this
# tfvars describes: wrong requester account, wrong requester CIDR, or aimed at a
# different local VPC.
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
# Neither the accepter resource nor the routes address the local VPC: one is
# addressed by peering id, the others by route table id. The module is here for
# ONE value — the VPC id, which the third provenance precondition compares the
# request's target against. Without it that guard has nothing to compare with.
#
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

################################################################################
# The request, read back from the API
#
# var.pcx_id arrives as a hand-copied string, and the accepter resource does not
# check where it came from: it accepts. This data source is what turns the id
# into facts that can be compared with what the tfvars claims — who opened the
# request (owner_id), from which block (cidr_block), and at which local VPC
# (peer_vpc_id).
#
# Reading it costs one DescribeVpcPeeringConnections call and no permission this
# root does not already need. A pending-acceptance connection IS returned to the
# accepter account, which is the state this runs in; an expired or mistyped id
# fails the data source itself, before anything is accepted.
#
# ORIENTATION, because the field names are only obvious once: from either side,
# `owner_id`/`vpc_id`/`cidr_block` describe the REQUESTER (the control plane) and
# `peer_*` describe the ACCEPTER (this stack). So owner_id is compared with
# var.peer_account_id and peer_vpc_id with the LOCAL vpc id — not the reverse.
################################################################################

data "aws_vpc_peering_connection" "requested" {
  id = var.pcx_id
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

  lifecycle {
    # PROVENANCE. auto_accept accepts whatever id it is handed, and a peering
    # request can be opened by ANY AWS account against a VPC in this one — it
    # arrives silently, costs the opener nothing, and sits in pending-acceptance
    # until somebody accepts it. Accepting the wrong pcx- and then routing
    # 10.59.0.0/16 into it does not fail: from inside this VPC it looks exactly
    # like a working control plane, while the traffic goes somewhere else.
    #
    # A typo in the tfvars produces the same outcome by accident: the two ids in
    # pcx_ids differ by a few hex characters, and swapping stg for prd accepts a
    # real connection aimed at the wrong VPC.
    #
    # These three checks are the whole answer, and each names a different lie the
    # id could be telling.
    precondition {
      condition     = data.aws_vpc_peering_connection.requested.owner_id == var.peer_account_id
      error_message = "pcx_id ${var.pcx_id} was opened by account ${data.aws_vpc_peering_connection.requested.owner_id}, not by peer_account_id ${var.peer_account_id}. Any AWS account can open a peering request against a VPC in this one; accepting it and routing peer_cidr into it points this stack's traffic at a VPC nobody here controls. Accept only the request opened by the control-plane account, and if that id looks wrong, do not widen peer_account_id — find out who opened the other one."
    }

    precondition {
      condition     = data.aws_vpc_peering_connection.requested.cidr_block == var.peer_cidr
      error_message = "pcx_id ${var.pcx_id} comes from a VPC whose CIDR is ${data.aws_vpc_peering_connection.requested.cidr_block}, but peer_cidr says ${var.peer_cidr}. The routes this root creates send that block over this connection, so a mismatch routes real traffic into a peering that cannot answer for those addresses. peer_cidr must be the CIDR of the VPC on the other end of THIS connection — the control plane, 10.59.0.0/16."
    }

    precondition {
      condition     = data.aws_vpc_peering_connection.requested.peer_vpc_id == module.network.vpc_id
      error_message = "pcx_id ${var.pcx_id} was requested against VPC ${data.aws_vpc_peering_connection.requested.peer_vpc_id}, but environment ${var.environment} resolves to ${module.network.vpc_id}. This is what swapping the stg and prd entries of pcx_ids looks like: a real connection, accepted in the wrong stack, where the acceptance succeeds and no route ever carries traffic. Take the entry of pcx_ids whose key matches this environment."
    }
  }
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
#
# AND THERE IS NO CIDR-OVERLAP GUARD HERE, DELIBERATELY. The obvious one — refuse
# a peer_cidr that overlaps the local VPC — cannot be reached. The second
# provenance precondition above already requires peer_cidr to EQUAL the CIDR the
# API reports for this connection's requester, and AWS refuses to create a
# peering between overlapping CIDRs in the first place, so a connection whose real
# requester block overlaps this VPC does not exist to be accepted. Any other
# peer_cidr fails provenance, on the accepter, before a route is planned. A guard
# on the route would only ever run after that one had passed, with a value that
# had already been proven equal to the real one.
################################################################################

resource "aws_route" "to_control_plane" {
  for_each = toset(var.route_table_ids)

  route_table_id            = each.value
  destination_cidr_block    = var.peer_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.this.vpc_peering_connection_id
}
