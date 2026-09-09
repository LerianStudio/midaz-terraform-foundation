variable "region" {
  description = "AWS region the certificate is issued in. Route53 is global; ACM IS NOT — a certificate is regional, and an ALB can only reference one issued in its own region. (CloudFront is the exception that needs us-east-1; there is no CloudFront on this estate.)"
  type        = string
  default     = "us-east-1"
}

variable "product" {
  description = "Pinned to \"network\". lerian-infra discovers roots by walking products/*/*, so the directory this root sits in is also the name `--target` takes, and the Product tag agrees with it rather than describing a service that does not exist."
  type        = string
  default     = "network"

  validation {
    condition     = var.product == "network"
    error_message = "This root is products/network/lerian-dev-zones and its Product tag is \"network\". A real product gets its own directory."
  }
}

variable "environment" {
  description = <<-EOT
    Deployment environment. One of dev, stg or prd.

    It tags the zone and the certificate, and it decides which state owns them.
    Which environment a given zone belongs in is not a free choice — main.tf holds
    the pairing and refuses a mismatch, because AWS accepts any pairing and a wrong
    one puts production's DNS in another environment's state.
  EOT

  type = string

  validation {
    condition     = contains(["dev", "stg", "prd"], var.environment)
    error_message = "environment must be dev, stg or prd. It feeds tags and the backend state key, so a value like \"prod\" applies cleanly and produces a zone no other stack resolves."
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
    Fully qualified name of the zone this apply creates, without a trailing dot.
    One of exactly three names, and the list below is the whole permitted set.

    A closed list rather than a pattern: the scheme this root serves is
    `<service>.<environment>.lerian.dev`, so the ZONES are the three environment
    labels and everything else is a record inside one of them. A pattern check
    that merely required a `.lerian.dev` suffix would accept the apex itself, a
    fourth environment nobody agreed to, and `a.b.lerian.dev`, each of which
    creates an orphan zone that resolves for nobody and an ACM validation that can
    never complete.

    Adding a zone here is a deliberate edit of this root and of main.tf's
    environment map, reviewed like any other change to what production resolves.
  EOT

  type = string

  validation {
    condition     = contains(["prd.lerian.dev", "stg.lerian.dev", "devops.lerian.dev"], var.zone_name)
    error_message = "zone_name must be exactly one of prd.lerian.dev, stg.lerian.dev or devops.lerian.dev. This root creates the three environment zones of the lerian.dev scheme and nothing else: it does not take over the apex, it does not create a second-level child such as a.b.lerian.dev, and it does not invent a fourth environment. Everything below an environment zone is a DNS record written by external-dns, not a zone."
  }
}

################################################################################
# Certificate validation
################################################################################

variable "wait_for_validation" {
  description = <<-EOT
    Block the apply until ACM reports the certificate validated.

    FALSE is the default here, unlike products/lerian-platform/dns. Validation
    needs an NS record in the lerian.dev apex, which lives in the management
    account that no root in this estate reaches, so the delegation is always a
    later step performed by somebody else. A blocking wait would spend its entire
    timeout on a step that has not begun.

    With it false the apply completes, `certificate_validated` reports false, and
    ACM keeps retrying for 72 hours — which covers the delegation landing, with no
    second apply. Set it true only when the delegation is already in place and you
    want the apply to confirm the certificate reached ISSUED.
  EOT

  type    = bool
  default = false
}

variable "validation_timeout" {
  description = "How long to wait for ACM validation when wait_for_validation is true. Only reachable with that flag on, which means the delegation is already done, so this is a bound on ACM's own polling rather than on a human step."
  type        = string
  default     = "45m"
}
