################################################################################
# A peering id proves nothing on its own — these runs are what makes that true
#
# auto_accept = true accepts whichever pcx- the tfvars names, and ANY AWS account
# can open a peering request against a VPC in this one: it arrives silently, costs
# the opener nothing, and waits in pending-acceptance. Accepting the wrong one and
# routing peer_cidr into it points this stack's 10.59.0.0/16 traffic at a VPC
# nobody here controls, and from inside the VPC that is indistinguishable from a
# working control plane. The same outcome arrives by accident when the stg and prd
# entries of pcx_ids are swapped.
#
# So the root reads the connection back from the API and compares three facts with
# what the tfvars claims. Each run below diverges exactly ONE of them:
#
#   owner_id    -> peer_account_id   a request opened by somebody else
#   cidr_block  -> peer_cidr         routes sent to a peering that cannot answer
#                                    for that block
#   peer_vpc_id -> the local VPC     a real connection accepted in the wrong stack
#
# ORIENTATION, because the field names read backwards once: from either side,
# owner_id/vpc_id/cidr_block describe the REQUESTER (the control plane) and peer_*
# describe the ACCEPTER (this stack).
#
# mock_provider: no AWS call, no credential, no state. override_data supplies the
# connection the API would return, override_module supplies the local VPC — the
# two things a plan without credentials cannot know, which is the only reason
# these preconditions would otherwise be deferred to apply.
#
# terraform test needs Terraform >= 1.7 (mock_provider). The root's own floor
# stays required_version >= 1.5.0 — that floor is what the root APPLIES under,
# and this file is a local proof, not a step of the foundation's CI.
################################################################################

mock_provider "aws" {}

variables {
  region          = "sa-east-1"
  environment     = "prd"
  pcx_id          = "pcx-0123456789abcdef0"
  peer_account_id = "159142082896"
  peer_cidr       = "10.59.0.0/16"
  route_table_ids = ["rtb-0123456789abcdef0"]
}

run "provenance_ok" {
  command = plan

  override_module {
    target = module.network
    outputs = {
      vpc_id = "vpc-0aaaaaaaaaaaaaaaa"
    }
  }

  override_data {
    target = data.aws_vpc_peering_connection.requested
    values = {
      owner_id    = "159142082896"
      cidr_block  = "10.59.0.0/16"
      peer_vpc_id = "vpc-0aaaaaaaaaaaaaaaa"
    }
  }
}

run "wrong_requester_account_refused" {
  command = plan

  # The connection is real and aimed at the right VPC — it was opened by somebody
  # else. This is the unsolicited request that costs its opener nothing.
  override_module {
    target = module.network
    outputs = {
      vpc_id = "vpc-0aaaaaaaaaaaaaaaa"
    }
  }

  override_data {
    target = data.aws_vpc_peering_connection.requested
    values = {
      owner_id    = "999999999999"
      cidr_block  = "10.59.0.0/16"
      peer_vpc_id = "vpc-0aaaaaaaaaaaaaaaa"
    }
  }

  expect_failures = [aws_vpc_peering_connection_accepter.this]
}

run "wrong_requester_cidr_refused" {
  command = plan

  # Right account, right target VPC, and peer_cidr does not describe the block on
  # the other end. The routes would send 10.59.0.0/16 into a peering that cannot
  # answer for those addresses.
  override_module {
    target = module.network
    outputs = {
      vpc_id = "vpc-0aaaaaaaaaaaaaaaa"
    }
  }

  override_data {
    target = data.aws_vpc_peering_connection.requested
    values = {
      owner_id    = "159142082896"
      cidr_block  = "10.99.0.0/16"
      peer_vpc_id = "vpc-0aaaaaaaaaaaaaaaa"
    }
  }

  expect_failures = [aws_vpc_peering_connection_accepter.this]
}

run "stg_and_prd_ids_swapped_refused" {
  command = plan

  # A real connection from the control plane, requested against the OTHER stack's
  # VPC: this is what taking the wrong entry of pcx_ids looks like. The acceptance
  # would succeed and no route would ever carry traffic.
  override_module {
    target = module.network
    outputs = {
      vpc_id = "vpc-0aaaaaaaaaaaaaaaa"
    }
  }

  override_data {
    target = data.aws_vpc_peering_connection.requested
    values = {
      owner_id    = "159142082896"
      cidr_block  = "10.59.0.0/16"
      peer_vpc_id = "vpc-0bbbbbbbbbbbbbbbb"
    }
  }

  expect_failures = [aws_vpc_peering_connection_accepter.this]
}
