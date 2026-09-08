variable "region" {
  description = "AWS region the peering connections are created in. Must be the region the infra-base VPC lives in; a peering to a VPC in another region needs peer_region, which this root deliberately does not set because both accounts of this estate are in one region."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", var.region))
    error_message = "The region must be a valid AWS region identifier, e.g. sa-east-1."
  }
}

variable "product" {
  description = "Product label used for tags and for the derived peering name (lerian-{env}-peering-{peer}). Defaults to \"lerian\", the reserved label for base foundation resources: a VPC peering belongs to the network of the whole account, not to one product."
  type        = string
  default     = "lerian"
}

variable "environment" {
  description = "Deployment environment of the LOCAL side. One of dev, stg or prd. It also selects the VPC, by tag:Name = \"lerian-{environment}-vpc\". This root runs in the control-plane account, where that environment is \"dev\"."
  type        = string
}

variable "extra_tags" {
  description = "Additional tags merged on top of the standard Lerian tag set."
  type        = map(string)
  default     = {}
}

################################################################################
# The local side
################################################################################

variable "route_table_ids" {
  description = <<-EOT
    Route tables in the LOCAL VPC that get a route to each peer. Normally the
    private route tables of infra-base/vpc — `terraform output
    private_route_table_ids` of that root, in this environment.

    Without a route the peering is ACTIVE and carries nothing, which is the most
    common way a correct peering looks broken.
  EOT

  type = list(string)

  validation {
    condition     = length(var.route_table_ids) > 0
    error_message = "At least one route_table_id is required. A peering with no route on either side is a connection that carries no traffic; an empty list here would apply cleanly and route nothing."
  }
}

################################################################################
# The remote side
################################################################################

variable "peers" {
  description = <<-EOT
    VPCs in the OTHER account to peer with, keyed by a short name that ends up in
    the peering's Name tag and in the pcx_ids output — that key is how the
    accepter tfvars on the other side is matched to the right connection, so it
    is a stable identifier, not a label.

    One entry per application stack: {stg = {...}, prd = {...}}. There is no
    entry pointing one stack at the other — the stacks are never peered.
  EOT

  type = map(object({
    account_id = string
    vpc_id     = string
    cidr       = string
  }))

  validation {
    condition     = alltrue([for peer in var.peers : can(regex("^[0-9]{12}$", peer.account_id))])
    error_message = "Every peer account_id must be exactly 12 digits. A peering request sent to the wrong owner id fails with an opaque API error, and one sent to THIS account's id would be a same-account peering that auto_accept = false never completes."
  }

  validation {
    condition     = alltrue([for peer in var.peers : can(regex("^vpc-[0-9a-f]{8,17}$", peer.vpc_id))])
    error_message = "Every peer vpc_id must look like vpc-0123456789abcdef0. The unresolved placeholder this tfvars ships with is caught here as well as by lerian-infra."
  }

  validation {
    condition = alltrue([
      for peer in var.peers :
      can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$", peer.cidr)) &&
      can(cidrhost(peer.cidr, 0))
    ])
    error_message = "Every peer cidr must be a valid IPv4 CIDR block, e.g. 10.61.0.0/16. It becomes the destination_cidr_block of a route in this VPC, so a malformed or wrong value here routes real traffic into a black hole. IPv6 is refused rather than passed through: aws_route writes destination_cidr_block, which is the IPv4 attribute, and an IPv6 block belongs in destination_ipv6_cidr_block — a resource argument this root does not set. cidrhost accepts fd00::/8 and every route built from it would fail at apply, or worse, be written as a v4 destination nobody meant."
  }

  validation {
    # NORMALISED, not the raw strings: AWS masks destination_cidr_block to its
    # network address, so 10.61.0.0/16 and 10.61.1.0/16 are the same destination
    # over there and distinct() on what was typed would not see it. try() falls
    # back to the raw value when the block is malformed — that case belongs to
    # the validation above, and a cidrhost error here would replace its message
    # with an evaluation failure.
    condition = length(distinct([
      for peer in var.peers :
      try("${cidrhost(peer.cidr, 0)}/${split("/", peer.cidr)[1]}", peer.cidr)
    ])) == length(var.peers)
    error_message = "Every peer cidr must be a DISTINCT block. Two peers sharing one produce two aws_route instances with the same route_table_id and the same destination_cidr_block: the for_each keys differ, so the plan succeeds and says nothing. AWS then refuses the second route with RouteAlreadyExists mid-apply, after both peering connections have already been created — and a half-applied peering pair is the state this root's other guards exist to avoid. The overlap guard in main.tf does not cover this: it compares each peer against the LOCAL VPC, never the peers against each other."
  }
}
