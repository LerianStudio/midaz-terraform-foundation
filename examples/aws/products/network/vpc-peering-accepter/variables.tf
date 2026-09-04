variable "region" {
  description = "AWS region the peering is accepted in. Must be the region of the LOCAL VPC. A peering whose two sides are in different regions needs peer_region on the requester, which that root deliberately does not set: both accounts of this estate are in one region."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", var.region))
    error_message = "The region must be a valid AWS region identifier, e.g. sa-east-1."
  }
}

variable "product" {
  description = "Product label used for tags and for the derived peering name (lerian-{env}-peering). Defaults to \"lerian\", the reserved label for base foundation resources: a VPC peering belongs to the network of the whole account, not to one product."
  type        = string
  default     = "lerian"
}

variable "environment" {
  description = "Deployment environment of the LOCAL side, and the environment this apply belongs to. One of dev, stg or prd. It also selects the VPC, by tag:Name = \"lerian-{environment}-vpc\". This root runs in the application account, where that environment is \"stg\" or \"prd\" — one apply each, one state each."
  type        = string
}

variable "extra_tags" {
  description = "Additional tags merged on top of the standard Lerian tag set."
  type        = map(string)
  default     = {}
}

################################################################################
# The other side, as a value that already exists
################################################################################

variable "pcx_id" {
  description = <<-EOT
    Id of the peering connection to accept, created by
    products/network/vpc-peering-requester in the control-plane account:
    `terraform output pcx_ids` there, then the entry for THIS stack.

    This is the whole cross-account handoff. The id is not a secret and not
    derived — it is written into the tfvars of this environment by hand, after
    the requester applies, and reviewed like any other value.

    A pending request EXPIRES AFTER 7 DAYS. An id copied from an expired request
    fails the apply rather than accepting anything, which is the good outcome.
  EOT

  type = string

  validation {
    condition     = can(regex("^pcx-[0-9a-f]{8,17}$", var.pcx_id))
    error_message = "pcx_id must look like pcx-0123456789abcdef0. The unresolved placeholder this tfvars ships with is caught here as well as by lerian-infra."
  }
}

variable "peer_account_id" {
  description = <<-EOT
    AWS account that OPENED this peering request — the control plane,
    159142082896. It is not used to build anything: it is the value the request
    read back from the API has to match before this stack accepts it.

    It exists because a peering id proves nothing on its own. Any AWS account can
    open a peering request against a VPC in this one; it arrives silently, costs
    the opener nothing, and waits in pending-acceptance for somebody to accept
    it. `auto_accept = true` accepts whichever id the tfvars names, and the
    routes then send the whole peer_cidr block into it — which, from inside this
    VPC, is indistinguishable from a working control plane.
  EOT

  type = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.peer_account_id))
    error_message = "peer_account_id must be exactly 12 digits — an AWS account id, e.g. 159142082896. An id with a stray character would make the provenance precondition compare against something no account can equal, turning a guard into an unconditional failure."
  }
}

variable "peer_cidr" {
  description = <<-EOT
    CIDR block of the REMOTE VPC — the control plane, 10.59.0.0/16. It becomes
    the destination_cidr_block of a route in every local route table listed
    below. A value that is merely wrong applies cleanly and feeds real traffic to
    a peering that drops it; a value that overlaps this VPC is refused by AWS
    only mid-apply, after the acceptance. The overlap guard in main.tf is what
    makes the second case fail at plan time instead.
  EOT

  type = string

  validation {
    condition     = can(cidrhost(var.peer_cidr, 0))
    error_message = "peer_cidr must be a valid CIDR block, e.g. 10.59.0.0/16."
  }
}

################################################################################
# The local side
################################################################################

variable "route_table_ids" {
  description = <<-EOT
    Route tables in the LOCAL VPC that get a route back to the control plane.
    Normally the private route tables of infra-base/vpc — `terraform output
    private_route_table_ids` of that root, in this environment.

    Routing is per direction and per route table: the requester's routes only get
    packets OUT of the control plane. Without these the peering is ACTIVE, the
    control plane can send, and nothing comes back.
  EOT

  type = list(string)

  validation {
    condition     = length(var.route_table_ids) > 0
    error_message = "At least one route_table_id is required. An accepted peering with no local route carries no return traffic; an empty list here would apply cleanly, accept the connection, and route nothing — and it would also skip the CIDR overlap guard, which is attached to the route."
  }
}
