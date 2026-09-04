variable "region" {
  description = "AWS region the provider talks to. Route53 is a GLOBAL service — the records this root writes are not placed in a region, and this value only selects the endpoint the API call goes through. Kept for parity with every other root in the estate, whose tfvars all open with it."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = <<-EOT
    Deployment environment. One of dev, stg or prd.

    It names nothing and tags nothing here — a Route53 record takes neither — and
    exists for one reason: this root's state key carries no environment, so the
    environment is the only thing that decides which state owns these NS records.
    The parent zone belongs to exactly one environment's state, and the
    precondition in main.tf holds this root to it.
  EOT

  type = string

  validation {
    condition     = contains(["dev", "stg", "prd"], var.environment)
    error_message = "The environment must be one of: dev, stg, prd. Every root that derives a resource name gets this closed set from _modules/naming; this one derives no name and declares no naming module, so the check is restated here rather than dropped."
  }
}

################################################################################
# The parent
################################################################################

variable "parent_zone_id" {
  description = <<-EOT
    Hosted zone id of the PARENT zone the NS records are written into:
    consignado.lerian.dev, created by products/lerian-platform/dns in environment
    prd of THIS account. Read it with `terraform output zone_id` on that root, in
    that environment.

    It is an id and not a name on purpose. Route53 has no unique-name lookup — a
    data source resolving "consignado.lerian.dev" would pick whichever zone of
    that name the caller can see, and this estate has two zones one label apart
    (the parent here, and hml.consignado.lerian.dev in the other account). The id
    is unambiguous and it is not a secret.
  EOT

  type = string

  validation {
    condition     = can(regex("^Z[A-Z0-9]+$", var.parent_zone_id))
    error_message = "parent_zone_id must be a Route53 hosted zone id, e.g. Z08918942Z5HSMYZ002F — uppercase, starting with Z, no /hostedzone/ prefix. The unresolved placeholder the tfvars ships with is caught here as well as by lerian-infra."
  }
}

################################################################################
# The children
################################################################################

variable "delegations" {
  description = <<-EOT
    Child zone FQDN (no trailing dot) -> the name servers that child zone
    published. One NS record per entry, in the parent zone.

    Each list is `terraform output name_servers` of the child's own
    products/lerian-platform/dns apply, in the child's own account and
    environment. The values are public data, they are not derived, and they are
    written into the tfvars by hand after that apply — which is the whole
    cross-account handoff this root exists to stop doing by clicking.

    Only zones whose delegation the PARENT owns belong here. In particular
    hml.consignado.lerian.dev does NOT: its NS record lives in lerian.dev in the
    management account, which no root in this account reaches. See README.md.
  EOT

  type = map(list(string))

  validation {
    condition = alltrue([
      for name in keys(var.delegations) :
      can(regex("^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$", name))
    ])
    error_message = "Every key must be a lowercase fully qualified domain name with no trailing dot, e.g. stg.consignado.lerian.dev. Route53 accepts a relative name and silently appends the zone, which turns a typo into a record for stg.consignado.lerian.dev.consignado.lerian.dev that resolves for nobody."
  }

  validation {
    condition = alltrue([
      for servers in values(var.delegations) :
      length(servers) <= 6 &&
      length(distinct([for s in servers : lower(trimsuffix(s, "."))])) >= 2
    ])
    error_message = "Every delegation must list between 2 and 6 name servers, and at least 2 of them must be DISTINCT. Route53 hands out exactly 4 per zone, and a list of 1 is almost always a truncated copy-and-paste: the delegation would apply cleanly, resolve while that single server answers, and take the child zone off the internet the moment it does not. A list that repeats one server has exactly that failure mode while looking like a list of 4 — DNS treats an NS set as a set, so duplicates collapse to one effective server, and the count is compared on names lowercased and stripped of their trailing dot because ns-1.example. and NS-1.EXAMPLE are the same host written twice."
  }
}
