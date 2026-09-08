################################################################################
# products/network/route53-delegation — the NS records that make the child zones
# resolvable, as code instead of as a step in a runbook
#
# products/lerian-platform/dns creates a child zone in each account and emits its
# four name servers, then stops: the record that points at them has to be created
# in the PARENT zone, which lives somewhere else. Its main.tf and README call that
# "the one manual step on the whole estate". For every child under
# consignado.lerian.dev, this root is that step.
#
# The parent zone consignado.lerian.dev lives in THIS account, in the `prd` state
# of products/lerian-platform/dns. So the delegation of its children is not a
# cross-account click at all — it is a Terraform resource that happens to consume
# an output from another account:
#
#   1. apply lerian-platform/dns in the child's account and environment
#   2. terraform output name_servers
#   3. write it into delegations in this root's tfvars
#   4. apply THIS root
#
# Both applies are IaC. Nothing here is clicked. The values crossing the boundary
# are public name servers, reviewed in a pull request like any other value.
#
# NOTHING RESOLVES BEFORE THIS RUNS, AND THAT INCLUDES TLS. ACM validates a
# certificate by resolving a record inside the child zone from the public
# internet, which is impossible until the parent delegates. The child dns applies
# therefore set wait_for_validation = false (otherwise they stall 45 minutes and
# fail); their certificates then issue on their own, within the 72 hours ACM keeps
# retrying, as soon as this root applies. There is no TLS window to schedule.
#
# WHY IT LIVES UNDER products/ WHEN IT IS NOT A PRODUCT. lerian-infra discovers
# roots by walking products/*/* and nothing else, and its infra-base stage is
# hardcoded to exactly vpc and eks (pkg/infra/discover.go:36-78, :128-153). A root
# at infra-base/dns-delegation would be invisible to the CLI: no ordering, no
# account guard, no state key. Precedent: products/lerian-platform/dns.
#
# NO NAMING MODULE, NO TAGS. A Route53 record is not taggable and is the only
# resource kind here, so module.naming and extra_tags would both be inputs with
# nowhere to land — see providers.tf.
################################################################################

resource "aws_route53_record" "ns" {
  for_each = var.delegations

  zone_id = var.parent_zone_id
  name    = each.key
  type    = "NS"
  records = each.value

  # 300 seconds, matching the TTL the manual step has always used
  # (infra/README.md, "The manual step"). Short on purpose: a delegation is the
  # one record that has to be re-pointed when a child zone is rebuilt, and a long
  # TTL turns that into an hours-long outage for every resolver that cached it.
  ttl = 300

  # allow_overwrite stays at its default of false. If an NS record for this child
  # already exists in the parent zone, the apply FAILS instead of taking the
  # record over. That is the outcome we want: this account's parent zone already
  # carries an NS record for hml.consignado.lerian.dev that nothing consults, and
  # adopting a record that some other process owns is how a working delegation
  # silently changes hands.

  lifecycle {
    # ONE STATE OWNS THESE RECORDS. The parent zone consignado.lerian.dev belongs
    # to the `prd` state of products/lerian-platform/dns in this account, and the
    # state key of THIS root carries no environment (see backend.tf): the
    # environment lives in the bucket name. So applying this root as anything but
    # `prd` does not fail on its own — it succeeds, into a second state, that owns
    # the same NS records in the same zone. From then on the two states disagree
    # silently, and a destroy in either one takes the child zones off the public
    # internet (and stops ACM renewing their certificates) while the other still
    # reports the delegation present.
    #
    # This is the frozen contract, not a preference: route53-delegation applies in
    # account 862902859103, environment prd, once. A future delegation of
    # grandchildren under stg.consignado.lerian.dev would write into a DIFFERENT
    # parent zone and needs its own root with its own state key — not a widening
    # of this check.
    precondition {
      condition     = var.environment == "prd"
      error_message = "environment is \"${var.environment}\", but this root only applies as \"prd\": the parent zone consignado.lerian.dev belongs to the prd state of products/lerian-platform/dns in this account, and this root's state key carries no environment. A second environment would create a second state owning the same NS records, where a destroy in either silently removes the delegation the other believes it owns. Fix the tfvars or the --env flag rather than this guard."
    }
  }
}
