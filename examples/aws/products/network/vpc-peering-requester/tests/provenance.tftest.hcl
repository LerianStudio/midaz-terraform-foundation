################################################################################
# The declared peer CIDR, checked against the one the peer VPC really has
#
# This is the requester-side mirror of the accepter's cidr_block provenance check
# (products/network/vpc-peering-accepter/tests/provenance.tftest.hcl). peers[*]
# .cidr is a hand-written claim about a VPC in another account, and it becomes the
# destination_cidr_block of a real route. The overlap guard only proves the claim
# does not collide with THIS VPC: a block that is simply wrong about the peer —
# 10.61.0.0/16 written for a VPC that is really 10.62.0.0/16 — collides with
# nothing, applies cleanly, and sends that traffic into a peering whose far end
# does not own the addresses. From inside the VPC that is indistinguishable from
# a firewall dropping packets.
#
# The check reads the connection back from the API, so it has exactly one blind
# moment and these runs pin both sides of it:
#
#   peer_cidr_block empty   -> pending-acceptance, nothing to compare, route made
#   peer_cidr_block equal   -> the claim was true, route made
#   peer_cidr_block differs -> refused, naming both blocks
#
# THE THREE RUNS ARE A SEQUENCE, NOT THREE CASES. Runs in one file share state,
# and that is what lets this file reproduce the real timeline: the first two
# apply — on a plan that CREATES the peering its id is unknown, the data source
# read is deferred, and the check is deferred with it, which is precisely the
# first-apply blindness — and the third only plans, against the connection they
# left in state. That third plan is the moment production refuses a wrong CIDR.
# Under mock_provider an apply reaches no AWS and needs no credential.
#
# override_module supplies the local VPC (the overlap guard reads its CIDR);
# override_data supplies what the API would say about the connection. Those are
# the two facts no run without credentials can know.
################################################################################

mock_provider "aws" {}

variables {
  region          = "sa-east-1"
  environment     = "dev"
  route_table_ids = ["rtb-0123456789abcdef0"]

  peers = {
    stg = {
      account_id = "862902859103"
      vpc_id     = "vpc-0aaaaaaaaaaaaaaaa"
      cidr       = "10.61.0.0/16"
    }
  }
}

run "pending_acceptance_is_silent" {
  command = apply

  override_module {
    target = module.network
    outputs = {
      vpc_id         = "vpc-0bbbbbbbbbbbbbbbb"
      vpc_cidr_block = "10.59.0.0/16"
    }
  }

  # "CIDR block information is only returned when describing an active VPC
  # peering connection" — so this is what the first apply really sees. The route
  # is created and sits in blackhole until the other account accepts.
  override_data {
    target = data.aws_vpc_peering_connection.this["stg"]
    values = {
      peer_cidr_block = ""
    }
  }
}

run "declared_cidr_matches_reality" {
  command = apply

  override_module {
    target = module.network
    outputs = {
      vpc_id         = "vpc-0bbbbbbbbbbbbbbbb"
      vpc_cidr_block = "10.59.0.0/16"
    }
  }

  override_data {
    target = data.aws_vpc_peering_connection.this["stg"]
    values = {
      peer_cidr_block = "10.61.0.0/16"
    }
  }
}

run "declared_cidr_wrong_about_the_peer_vpc_refused" {
  # PLAN, and the two runs above are why it can be. Runs in one file share
  # state, so by here the connection exists and its id is known — the data
  # source is readable at plan and the check lands there. That is the real
  # sequence in production: the first apply creates the route blind, and the
  # NEXT plan is where a wrong CIDR is refused.
  command = plan

  override_module {
    target = module.network
    outputs = {
      vpc_id         = "vpc-0bbbbbbbbbbbbbbbb"
      vpc_cidr_block = "10.59.0.0/16"
    }
  }

  # A connection that is active, opened against the right VPC, and whose far end
  # owns 10.62.0.0/16 — not the 10.61.0.0/16 the tfvars claims. Disjoint from the
  # local VPC, so the overlap guard has nothing to say about it.
  override_data {
    target = data.aws_vpc_peering_connection.this["stg"]
    values = {
      peer_cidr_block = "10.62.0.0/16"
    }
  }

  expect_failures = [aws_route.to_peer]
}
