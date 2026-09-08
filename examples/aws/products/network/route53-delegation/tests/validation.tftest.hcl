################################################################################
# A delegation of four name servers can be a delegation to one
#
# An NS record set is a SET. Route53 accepts ["ns-1.example.", "ns-1.example."]
# and publishes one effective server; a resolver that cannot reach it has nowhere
# else to go, and the child zone — with every certificate ACM renews inside it —
# is off the public internet. The old check counted list length, so the truncated
# copy-and-paste it existed to catch passed the moment the truncated value was
# pasted twice.
#
# The count is now taken over distinct servers, compared lowercased and without
# the trailing dot, because a hostname written in two spellings is still one host.
# The runs below diverge exactly that: same length, same shape, only the number of
# real servers changes.
#
# mock_provider: no AWS call, no credential, no state. This root creates one
# resource kind, aws_route53_record, and reads no data source, so the mock has
# nothing to stand in for beyond the API call itself.
#
# environment is "prd" in every run because main.tf refuses any other value: the
# parent zone belongs to the prd state of products/lerian-platform/dns, and a
# second state owning the same NS records is the failure that precondition
# exists for. That is not what these runs are about.
#
# terraform test needs Terraform >= 1.7 (mock_provider), and so does plain
# `terraform validate`: it PARSES tests/*.tftest.hcl rather than skipping them,
# and validate IS a CI step. So the root's floor is >= 1.7.0, not the 1.5.0 the
# rest of the tree carries — an older CLI fails here on an unsupported block.
################################################################################

mock_provider "aws" {}

variables {
  region         = "us-east-1"
  environment    = "prd"
  parent_zone_id = "Z08918942Z5HSMYZ002F"

  delegations = {
    "stg.consignado.lerian.dev" = [
      "ns-1.awsdns-00.com.",
      "NS-2.AWSDNS-01.CO.UK",
      "ns-3.awsdns-02.net",
      "ns-4.awsdns-03.org.",
    ]
  }
}

run "four_distinct_servers_accepted" {
  command = plan
}

run "the_same_server_four_times_refused" {
  command = plan

  # What a truncated copy-and-paste looks like once somebody pads it to four:
  # the record applies, resolves while that one host answers, and the zone
  # disappears the moment it does not.
  variables {
    delegations = {
      "stg.consignado.lerian.dev" = [
        "ns-1.awsdns-00.com.",
        "ns-1.awsdns-00.com.",
        "ns-1.awsdns-00.com.",
        "ns-1.awsdns-00.com.",
      ]
    }
  }

  expect_failures = [var.delegations]
}

run "two_spellings_of_one_server_refused" {
  command = plan

  # Length 2 and, to DNS, one server: the trailing dot and the case are not part
  # of the identity of a host.
  variables {
    delegations = {
      "stg.consignado.lerian.dev" = [
        "ns-1.awsdns-00.com.",
        "NS-1.AWSDNS-00.COM",
      ]
    }
  }

  expect_failures = [var.delegations]
}

run "seven_servers_refused" {
  command = plan

  # The upper bound still holds on the raw list, not on the distinct set: seven
  # different servers is a delegation nobody publishes, and is a sign the list
  # came from somewhere other than a single zone's output.
  variables {
    delegations = {
      "stg.consignado.lerian.dev" = [
        "ns-1.awsdns-00.com",
        "ns-2.awsdns-01.com",
        "ns-3.awsdns-02.com",
        "ns-4.awsdns-03.com",
        "ns-5.awsdns-04.com",
        "ns-6.awsdns-05.com",
        "ns-7.awsdns-06.com",
      ]
    }
  }

  expect_failures = [var.delegations]
}
