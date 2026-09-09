################################################################################
# products/lerian-platform/dns — the public edge: one hosted zone, one wildcard
# certificate
#
# THE FOUNDATION CREATES NO DNS AND NO CERTIFICATE ON AWS. `grep aws_route53` over
# the whole repository returned zero resources before this root, and so did
# `grep aws_acm_certificate`; the v1 route53 example was deleted on purpose in v2,
# and the root README says it outright: "It creates no DNS zone and no DNS record
# either." (The support matrix at README.md:18 claims infra-base creates a DNS
# zone — that is true for GCP and Azure and false for AWS.)
#
# What DOES exist is the IRSA for external-dns and cert-manager, which is the
# permission to write records, not the zone to write them into.
#
# WHY IT LIVES UNDER products/ WHEN IT IS NOT A PRODUCT. lerian-infra discovers
# roots by walking products/*/* and nothing else, and its infra-base stage is
# hardcoded to exactly vpc and eks (pkg/infra/discover.go:36-78, :128-153). A root
# at infra-base/dns would be invisible to the CLI: no ordering, no account guard,
# no state key — applied by hand or not at all. products/lerian-platform/dns is
# discovered, ordered and guarded like everything else.
#
################################################################################
# DELEGATION, NOT TRANSFER — and the one manual step on the whole estate
################################################################################
#
# The parent domain lives in a DIFFERENT AWS account. This root creates the CHILD
# zone here and emits its four name servers; somebody then creates ONE NS record in
# the parent zone pointing at them. That record is the only point of contact
# between the two accounts, it is one line, it is reversible in minutes, and it
# survives an ownership transfer of this account untouched.
#
# Transferring the domain instead would move every name already using it and is not
# reversible in minutes.
#
# THE CERTIFICATE WILL NOT ISSUE UNTIL THE DELEGATION EXISTS. ACM validates by
# resolving a record in this zone from the public internet, which cannot happen
# before the parent delegates. So `terraform apply` here BLOCKS on
# aws_acm_certificate_validation until somebody does the manual step, and then
# times out. That is the intended shape — a certificate that silently "succeeded"
# without validation would fail later, at the ALB, where it is much harder to read.
#
# Two-step apply:
#   1. -target=aws_route53_zone.this   -> read the name_servers output
#   2. create the NS record in the parent account, wait for propagation
#   3. plain apply                     -> the certificate validates
#
# Set wait_for_validation = false to skip the blocking wait entirely and validate
# out of band. The certificate is still created and still unusable until validated.
#
################################################################################
# WHAT THIS ROOT DOES NOT DO
#
# It installs nothing. external-dns and the AWS Load Balancer Controller are Helm
# releases in the phase after this one; their IAM roles already exist in
# infra-base/eks. There is no cert-manager on this estate and there does not need
# to be: TLS terminates at the ALB with the ACM certificate this root issues.
################################################################################

module "naming" {
  source = "../../../_modules/naming"

  product     = var.product
  environment = var.environment
  component   = "dns"
  extra_tags  = var.extra_tags
}

################################################################################
# Public hosted zone
################################################################################

resource "aws_route53_zone" "this" {
  name    = var.zone_name
  comment = "Public zone for ${var.zone_name}, delegated from the parent account. Records are written by external-dns from Ingress objects; do not author them by hand."

  tags = merge(module.naming.tags, { Name = var.zone_name })

  lifecycle {
    # Destroying a public zone that the parent still delegates to is a live outage
    # that no plan output makes obvious: the NS record keeps pointing at name
    # servers that no longer answer, and the failure is NXDOMAIN for every name in
    # the domain until somebody notices the delegation is dangling.
    #
    # The flag is a guard against an ACCIDENTAL destroy, not a lock: a zone that is
    # retired on purpose leaves through a release that sets this to false, a destroy
    # ordered parent-record-first (products/network/route53-delegation for a child
    # of another zone, the apex for a child of the apex), and a release that sets it
    # back. v1.9.2 was that off release for the consignado estate's
    # *.consignado.lerian.dev zones; this is the release that puts the guard back.
    prevent_destroy = true

    # The dot matters. endswith(zone, parent) alone accepts "xlerian.dev" against
    # parent "lerian.dev", because it has no notion of a label boundary; requiring
    # ".{parent}" pins the boundary. And the check has to be a real conjunction —
    # an earlier version wrote it as a disjunction, which only rejected
    # zone == parent and let a wholly unrelated domain through. A typo that gets
    # past here creates an orphan zone and then stalls the apply for 45 minutes in
    # an ACM validation that can never complete, which is precisely the class of
    # error a plan-time guard exists to catch.
    precondition {
      condition     = endswith(trimsuffix(var.zone_name, "."), ".${var.parent_zone_name}")
      error_message = "zone_name must be a SUBDOMAIN of parent_zone_name, ending in \".${var.parent_zone_name}\". This root delegates a child zone from a parent held in another account; it never takes over an apex, and it cannot delegate from a parent that is not actually the parent."
    }
  }
}

################################################################################
# Wildcard certificate
#
# Two names on one certificate: the apex and *.{apex}. A wildcard covers one label
# only — it matches gw.consignado.lerian.dev and does NOT match
# a.b.consignado.lerian.dev — which is why the apex is listed separately rather
# than assumed to be covered.
#
# DNS validation, not email: email validation needs a human to click a link in a
# mailbox nobody on this estate owns, and it does not renew unattended.
################################################################################

resource "aws_acm_certificate" "this" {
  domain_name               = var.zone_name
  subject_alternative_names = ["*.${var.zone_name}"]
  validation_method         = "DNS"

  tags = merge(module.naming.tags, { Name = "${var.zone_name}-wildcard" })

  lifecycle {
    # ACM certificates cannot be modified: any change to the name set replaces the
    # certificate, and a replace that deletes before it creates takes the ALB
    # listener down with it.
    create_before_destroy = true
  }
}

resource "aws_route53_record" "validation" {
  for_each = {
    for option in aws_acm_certificate.this.domain_validation_options :
    option.domain_name => {
      name   = option.resource_record_name
      record = option.resource_record_value
      type   = option.resource_record_type
    }
  }

  zone_id = aws_route53_zone.this.zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60

  # The apex and the wildcard produce the SAME validation record, and the map above
  # does NOT collapse to one entry: its key is option.domain_name, which differs
  # ("consignado.lerian.dev" and "*.consignado.lerian.dev") while resource_record_name,
  # _type and _value are identical. So two Terraform instances own one Route 53
  # record. allow_overwrite is what keeps that applying — both write the same UPSERT,
  # and it also keeps a re-apply after a certificate replacement from failing on a
  # record that already exists.
  #
  # Keying by resource_record_name/_type instead would collapse the pair to the one
  # instance that should exist, and it is the right shape. It is NOT a free edit here:
  # the estate has already applied this root, so changing the for_each key renames both
  # instances and the plan reads destroy-both-then-create-one on the live ACM validation
  # CNAME — which is also what ACM re-reads at renewal. It needs `moved` blocks (or a
  # state mv) and a plan reviewed per environment, not a drive-by rekey.
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "this" {
  count = var.wait_for_validation ? 1 : 0

  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [for record in aws_route53_record.validation : record.fqdn]

  timeouts {
    # Long, on purpose. This wait is what blocks until a human creates the NS record
    # in the parent account, and a short timeout would turn "the delegation is not
    # done yet" into a confusing apply failure several times before anyone reads the
    # header of this file.
    create = var.validation_timeout
  }
}
