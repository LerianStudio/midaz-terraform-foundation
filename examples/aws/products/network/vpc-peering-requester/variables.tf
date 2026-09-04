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
    condition     = alltrue([for peer in var.peers : can(cidrhost(peer.cidr, 0))])
    error_message = "Every peer cidr must be a valid CIDR block, e.g. 10.61.0.0/16. It becomes the destination_cidr_block of a route in this VPC, so a malformed or wrong value here routes real traffic into a black hole."
  }
}
