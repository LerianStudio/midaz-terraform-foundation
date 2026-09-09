################################################################################
# products/network/lerian-dev-zones — one environment zone under the lerian.dev
# apex, plus its wildcard certificate
#
# WHY THIS EXISTS WHEN products/lerian-platform/dns ALREADY CREATES A ZONE. That
# root creates one zone per Terraform environment and holds it in that
# environment's state. All three of its states are occupied: `consignado.lerian.dev`
# in prd, `stg.consignado.lerian.dev` in stg, `devops.consignado.lerian.dev` in dev
# of the other account. Pointing any of them at a new name would replace the zone
# inside a state that still owns the old one — a live outage for every name in the
# old domain, and its `prevent_destroy` turns that into a failed plan rather than a
# quiet one. A separate root leaves all three intact, which is what makes the two
# schemes able to coexist while consumers move over one at a time.
#
# ONE ZONE PER APPLY, AND THAT IS NOT AN OVERSIGHT. The estate needs three zones
# and they do not share a state:
#
#   prd.lerian.dev     account 862902859103 (saas),   environment prd
#   stg.lerian.dev     account 862902859103 (saas),   environment stg
#   devops.lerian.dev  account 159142082896 (devops), environment dev
#
# The first two sit in one account but in different Terraform environments, so a
# root creating both would put staging's zone in production's state, where a
# destroy of production removes staging's DNS. The third sits in another account
# entirely, which no single provider configuration reaches. And each zone is
# written by the external-dns of its own cluster, whose IAM policy scopes to
# `arn:aws:route53:::hostedzone/<id>` in ITS account — a role cannot be granted a
# hosted zone another account owns without a cross-account assume-role this estate
# does not have. Three applies, three states, one zone each.
#
# THIS ROOT NEVER TOUCHES THE PARENT. `lerian.dev` lives in the organisation's
# management account, which no root in this estate reaches. All three zones here
# are direct children of that apex, so each one needs an NS record created there by
# hand, once. That is different from the older scheme, where only
# `consignado.lerian.dev` came from the apex and its two subzones were delegated by
# Terraform inside this account (products/network/route53-delegation). Short names
# cost three manual delegations instead of one; that trade was made deliberately.
################################################################################

locals {
  # The apex every zone this root creates descends from. Not a variable: the root
  # is named for it, the allow-list in variables.tf enumerates its three children
  # by hand, and a configurable parent would be a knob whose only correct value is
  # this one.
  apex = "lerian.dev"

  # WHICH ENVIRONMENT EACH ZONE BELONGS IN. The zone name and the Terraform
  # environment are two independent inputs, and nothing about a hosted zone makes
  # a mismatch fail: `zone_name = "prd.lerian.dev"` with `environment = "stg"`
  # applies cleanly and puts production's DNS in staging's state, where a
  # `--action destroy` on staging takes production off the internet. The apply
  # would look completely ordinary. Hence the precondition below.
  zone_environment = {
    "prd.lerian.dev"    = "prd"
    "stg.lerian.dev"    = "stg"
    "devops.lerian.dev" = "dev"
  }
}

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
  comment = "Public zone for ${var.zone_name}, delegated from ${local.apex} in the management account. Records are written by external-dns from Ingress objects; do not author them by hand."

  tags = merge(module.naming.tags, { Name = var.zone_name })

  lifecycle {
    # Destroying a public zone the parent still delegates to is an outage no plan
    # output makes obvious: the NS record in the apex keeps pointing at name
    # servers that stopped answering, and every name in the domain returns
    # NXDOMAIN until somebody works out the delegation is dangling.
    prevent_destroy = true

    # Reading a failed plan here: removing a zone from this estate is a deliberate
    # edit of this root plus a matching removal of the NS record in the apex, in
    # that order. `prevent_destroy` refusing the plan is the intended answer to
    # anything less than that.

    precondition {
      condition     = local.zone_environment[var.zone_name] == var.environment
      error_message = "zone_name \"${var.zone_name}\" belongs in Terraform environment \"${local.zone_environment[var.zone_name]}\", and this apply is running as \"${var.environment}\". Applying it here would create that zone in the wrong state, where a destroy of THIS environment removes DNS the other environment believes it owns. The zone name and the environment are separate inputs and AWS accepts any pairing of them, so this is the only place the pairing is checked. Fix the --env flag or the tfvars, never this map."
    }
  }
}

################################################################################
# Wildcard certificate
#
# Two names on one certificate: the zone apex and *.{zone}. A wildcard covers a
# single label — it matches gw.prd.lerian.dev and does NOT match
# a.b.prd.lerian.dev — so the zone apex is listed explicitly rather than assumed
# to be covered by the wildcard.
#
# DNS validation, not email: email validation needs somebody to click a link in a
# mailbox nobody on this estate owns, and it does not renew unattended.
################################################################################

resource "aws_acm_certificate" "this" {
  domain_name               = var.zone_name
  subject_alternative_names = ["*.${var.zone_name}"]
  validation_method         = "DNS"

  tags = merge(module.naming.tags, { Name = "${var.zone_name}-wildcard" })

  lifecycle {
    # An ACM certificate cannot be modified: any change to its name set replaces
    # it, and a replace that deletes before it creates takes the ALB listener
    # referencing it down in between.
    create_before_destroy = true

    # THE VALIDATION RECORD'S OWN GUARD CANNOT CATCH ITS OWN ABSENCE, so this one
    # lives here.
    #
    # aws_route53_record.validation filters domain_validation_options down to the
    # element whose domain_name is the zone apex. If that filter ever matches
    # NOTHING -- ACM normalising the name differently, returning a trailing dot,
    # anything -- the for_each map is empty, the resource gets zero instances, and
    # Terraform reports no error at all: measured, the plan reads "2 to add" and
    # succeeds. A precondition inside that resource never runs, because a resource
    # with no instances evaluates no lifecycle block.
    #
    # The failure would then be silent and slow in the worst way: the zone and the
    # certificate both exist, nothing validates it, ACM retries for 72 hours and
    # gives up. No apply ever failed, and the first symptom is an ALB that will not
    # serve TLS.
    #
    # A postcondition on the certificate runs whether or not the record resource
    # has instances, and it reads self.domain_validation_options after creation,
    # when the values are known.
    postcondition {
      condition = length([
        for option in self.domain_validation_options :
        option if option.domain_name == var.zone_name
      ]) == 1
      error_message = "ACM returned no validation option whose domain_name is exactly \"${var.zone_name}\", or more than one. aws_route53_record.validation selects that single element, so an empty match creates NO validation record and fails no apply — the certificate would sit unvalidated until ACM gives up after 72 hours. Compare this certificate's domain_validation_options against the filter in that resource before applying again."
    }
  }
}

################################################################################
# Validation record — ONE instance, not two
#
# `domain_validation_options` returns one element per certificate name, so two
# here: the zone apex and the wildcard. Both elements carry the SAME
# resource_record_name, _type and _value, because ACM validates a wildcard through
# its parent's record. products/lerian-platform/dns keys its for_each by
# `option.domain_name`, which differs between the two elements, so it ends up with
# TWO Terraform instances managing ONE Route 53 record — a shape that only keeps
# applying because allow_overwrite lets each UPSERT over the other. That root is
# already applied, so re-keying it reads as destroy-both-then-create-one on the
# live validation CNAME ACM re-reads at renewal; it needs `moved` blocks and a
# per-environment plan review.
#
# WHY NOT SIMPLY KEY BY resource_record_name AND _type. Because Terraform cannot:
# those attributes are unknown until the certificate exists, and a for_each whose
# KEYS are unknown at plan time is rejected outright ("cannot determine the full
# set of keys"). Measured on 2026-09-09 — the plan refuses before it reaches AWS.
# The older root's key works precisely because `domain_name` is derived from the
# configuration and is therefore known. So the fix is not a better key: it is
# asking for one element instead of two.
#
# The filter keeps only the element whose domain_name is the zone apex, and the
# wildcard's identical record is not requested at all. Key known at plan time,
# apply-time values in the map value, one instance per record.
#
# The precondition guards the premise. If ACM ever stopped folding a wildcard into
# its parent's record, this root would create one of the two records the
# certificate needed and the validation would hang for 72 hours with nothing
# saying why. resource_record_name is known by then, so the check fires at apply
# and names the mismatch instead.
################################################################################

resource "aws_route53_record" "validation" {
  for_each = {
    for option in aws_acm_certificate.this.domain_validation_options :
    option.domain_name => option
    if option.domain_name == var.zone_name
  }

  zone_id = aws_route53_zone.this.zone_id
  name    = each.value.resource_record_name
  type    = each.value.resource_record_type
  records = [each.value.resource_record_value]
  ttl     = 60

  # Replacing this certificate — any edit to its name set — creates the new one
  # before destroying the old, and the new one asks for a validation record of the
  # same name and type that already exists. Without allow_overwrite that apply
  # fails on a record whose value is the one ACM is asking for anyway. It is NOT
  # here to paper over duplicate instances; the for_each above produces one.
  allow_overwrite = true

  lifecycle {
    precondition {
      condition = length(distinct([
        for option in aws_acm_certificate.this.domain_validation_options :
        "${option.resource_record_name}|${option.resource_record_type}|${option.resource_record_value}"
      ])) == 1
      error_message = "This certificate's validation options no longer describe a single DNS record. This root creates ONE record because ACM folds the wildcard's validation into the zone apex's record, so both options are byte-identical; that premise is what makes it safe to request only the apex's option. They now differ, which means the wildcard needs a record of its own that nothing here creates — the certificate would sit unvalidated for 72 hours with no error anywhere. Re-key the for_each to cover every distinct record before applying."
    }
  }
}

################################################################################
# Validation wait — off by default here
#
# products/lerian-platform/dns defaults this to true, because there the blocking
# wait is what surfaces a forgotten delegation. Here it defaults to FALSE, and the
# difference is which order the two steps run in.
#
# The apex is in the management account. Nobody running this apply can create the
# NS record, so the delegation is always a later step by another person: a
# blocking wait would spend its whole timeout on a step that has not started, fail
# the apply, and leave the operator unsure whether the zone was created. With the
# wait off, the apply completes, `certificate_validated` reports false, and ACM
# retries validation on its own for 72 hours — long enough for the delegation to
# land and the certificate to reach ISSUED with no further apply.
#
# There is no window without TLS, because there is no window with traffic: nothing
# resolves any of these names until the delegation exists.
################################################################################

resource "aws_acm_certificate_validation" "this" {
  count = var.wait_for_validation ? 1 : 0

  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [for record in aws_route53_record.validation : record.fqdn]

  timeouts {
    create = var.validation_timeout
  }
}
