################################################################################
# The peer CIDR is written into an IPv4 route, and only an IPv4 route
#
# aws_route.to_peer sets destination_cidr_block — the IPv4 attribute. The IPv6
# destination is a DIFFERENT argument (destination_ipv6_cidr_block) and this root
# does not set it, so an IPv6 block in peers[*].cidr has nowhere correct to land.
# The old check was can(cidrhost(cidr, 0)), which accepts fd00::/8 happily: the
# value would pass the plan, reach the route, and fail late or be written as a v4
# destination nobody meant. The overlap guard's arithmetic is v4-shaped too — it
# splits on "/" and compares network addresses.
#
# mock_provider: no AWS call, no credential, no state. override_module supplies
# the local VPC, which is the one thing a plan without credentials cannot know
# and which the overlap guard reads: without it the local CIDR is null and
# tonumber(split("/", null)) fails before any validation is reached.
#
# terraform test needs Terraform >= 1.7 (mock_provider). The root's own floor
# stays required_version >= 1.5.0 — that floor is what the root APPLIES under,
# and this file is a local proof, not a step of the foundation's CI.
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

run "ipv4_peer_cidr_accepted" {
  command = plan

  override_module {
    target = module.network
    outputs = {
      vpc_id         = "vpc-0bbbbbbbbbbbbbbbb"
      vpc_cidr_block = "10.59.0.0/16"
    }
  }
}

run "ipv6_peer_cidr_refused" {
  command = plan

  override_module {
    target = module.network
    outputs = {
      vpc_id         = "vpc-0bbbbbbbbbbbbbbbb"
      vpc_cidr_block = "10.59.0.0/16"
    }
  }

  # cidrhost() alone called this valid. There is no IPv6 route in this root for
  # it to become.
  variables {
    peers = {
      stg = {
        account_id = "862902859103"
        vpc_id     = "vpc-0aaaaaaaaaaaaaaaa"
        cidr       = "fd00::/8"
      }
    }
  }

  expect_failures = [var.peers]
}
