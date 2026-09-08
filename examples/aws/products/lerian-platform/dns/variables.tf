variable "region" {
  description = "AWS region the certificate is issued in. Route53 is global; ACM IS NOT — a certificate is regional and an ALB can only use one issued in its own region. (CloudFront is the exception that needs us-east-1; there is no CloudFront on this estate.)"
  type        = string
  default     = "us-east-1"
}

variable "product" {
  description = "Pinned to \"lerian-platform\". A pseudo-product for cluster-level roots that belong to no service — see main.tf for why they live under products/ at all."
  type        = string
  default     = "lerian-platform"

  validation {
    condition     = var.product == "lerian-platform"
    error_message = "This stack is lerian-platform. A real product gets its own directory."
  }
}

variable "environment" {
  description = "Deployment environment. One of dev, stg or prd. Tags only: the zone name carries the environment distinction itself, because the two accounts of this estate hold DIFFERENT domains rather than the same domain twice."
  type        = string

  validation {
    condition     = contains(["dev", "stg", "prd"], var.environment)
    error_message = "environment must be dev, stg or prd. It feeds resource names, tags and the backend state key, so a value like \"prod\" applies cleanly and produces resources no other stack resolves."
  }

}

variable "extra_tags" {
  description = "Additional tags merged on top of the standard Lerian tag set."
  type        = map(string)
  default     = {}
}

################################################################################
# The zone
################################################################################

variable "zone_name" {
  description = <<-EOT
    Fully qualified name of the PUBLIC zone this account owns, without a trailing
    dot. It must be a subdomain of parent_zone_name — this root delegates a child
    zone and never takes over an apex.

    Each account of this estate owns exactly one, and they are different names, not
    the same name twice: that is what makes the two accounts independent at the DNS
    layer while sharing one parent.
  EOT

  type = string

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$", var.zone_name)) && !endswith(var.zone_name, ".")
    error_message = "The zone_name must be a lowercase fully qualified domain name with no trailing dot, e.g. consignado.example.dev."
  }

  validation {
    condition     = length(split(".", var.zone_name)) >= 3
    error_message = "The zone_name must have at least three labels: it is a delegated SUBDOMAIN of a parent zone held in another account, not a registrable apex."
  }
}

variable "parent_zone_name" {
  description = "Name of the parent zone, which lives in a DIFFERENT AWS account and is not managed by this root. Used only to assert that zone_name really is a child of it. The NS record delegating to this zone is created by hand in that account, once — see the name_servers output."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$", var.parent_zone_name)) && !endswith(var.parent_zone_name, ".")
    error_message = "The parent_zone_name must be a lowercase fully qualified domain name with no trailing dot."
  }
}

################################################################################
# Certificate validation
################################################################################

variable "wait_for_validation" {
  description = "Block the apply until ACM has validated the certificate. TRUE is the honest default: validation cannot succeed until the parent account delegates, so this wait is what surfaces a missing delegation as a visible stall instead of as a broken ALB listener days later. Set false to create the certificate and validate out of band — it is still unusable until validated."
  type        = bool
  default     = true
}

variable "validation_timeout" {
  description = "How long to wait for ACM validation. Long on purpose: the wait is gated on a human creating an NS record in another account. Shorten it only when the delegation is known to be in place already."
  type        = string
  default     = "45m"
}
