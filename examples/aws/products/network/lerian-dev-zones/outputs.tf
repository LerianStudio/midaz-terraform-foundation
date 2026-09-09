output "mode" {
  description = "Published as a constant so `terraform output mode` answers uniformly across every root. A hosted zone has no shared tier."
  value       = "dedicated"
}

################################################################################
# THE MANUAL STEP
#
# Every zone this root creates is a direct child of the lerian.dev apex, and that
# apex lives in the organisation's management account. So each of the three applies
# ends with the same handoff: four name servers that somebody has to write into a
# zone no root here reaches.
################################################################################

output "name_servers" {
  description = "THE FOUR NAME SERVERS THE APEX MUST DELEGATE TO. In the account holding lerian.dev, create one NS record named `{zone_name}.` with these four values and TTL 300. Nothing resolves under this zone until that record exists — including the ACM validation this certificate is waiting on."
  value       = aws_route53_zone.this.name_servers
}

output "delegation_lines" {
  description = <<-EOT
    The manual step as one line of text, ready to paste with no reformatting:
    the zone name followed by its four name servers, space separated.

    Reformatting by hand is where a delegation gets truncated, and a truncated NS
    set is the worst kind of DNS failure: Route53 hands out exactly four servers
    per zone, a copy carrying one applies cleanly and resolves for as long as that
    single server answers, then takes the whole zone off the internet the moment
    it does not.

    Run it in each of the three states and concatenate. `wc -w` on any line is 5.
  EOT

  value = "${aws_route53_zone.this.name} ${join(" ", aws_route53_zone.this.name_servers)}"
}

output "delegation_instruction" {
  description = "The same step in prose, for a ticket or a runbook, so nobody has to reconstruct it from the other outputs."
  value = format(
    "In the account holding %s, create an NS record for '%s.' with TTL 300 and these values: %s",
    local.apex,
    aws_route53_zone.this.name,
    join(", ", aws_route53_zone.this.name_servers),
  )
}

################################################################################
# Zone
################################################################################

output "zone_id" {
  description = "Hosted zone id. Consumed by the external-dns and cert-manager IAM policies, which scope to arn:aws:route53:::hostedzone/{this} rather than to the wildcard the foundation's examples ship with."
  value       = aws_route53_zone.this.zone_id
}

output "zone_arn" {
  description = "Hosted zone ARN, ready to append to external_dns_hosted_zone_arns and cert_manager_hosted_zone_arns in this account's infra-base/eks tfvars. APPEND, do not replace: while both naming schemes coexist, external-dns still has to write into the old zone, and a policy that lost the old ARN would leave every existing record unmanageable. Take the value from here rather than assembling it from zone_id by hand."
  value       = "arn:aws:route53:::hostedzone/${aws_route53_zone.this.zone_id}"
}

output "zone_name" {
  description = "Name of the zone. Also the --domain-filter value external-dns needs for it: without a filter the controller considers every zone its role can reach, and during coexistence its role can reach two."
  value       = aws_route53_zone.this.name
}

################################################################################
# Certificate
################################################################################

output "certificate_arn" {
  description = "ARN of the wildcard certificate, for alb.ingress.kubernetes.io/certificate-arn. Reading this output is NOT evidence the certificate works — check certificate_validated."
  value       = aws_acm_certificate.this.arn
}

output "certificate_domains" {
  description = "Names the certificate covers: the zone apex and one wildcard label. It matches gw.{zone} and does NOT match a.b.{zone}."
  # distinct(): some provider versions repeat domain_name inside
  # subject_alternative_names, and a duplicated apex here reads as a certificate
  # name that does not exist.
  value = distinct(concat([aws_acm_certificate.this.domain_name], tolist(aws_acm_certificate.this.subject_alternative_names)))
}

output "certificate_validated" {
  description = "Whether THIS apply observed successful validation. It is false on the normal path, because wait_for_validation defaults to false here: the certificate exists, ACM is still retrying, and it reaches ISSUED once the apex delegation lands. An ALB listener referencing an unvalidated certificate does not serve TLS, so do not read certificate_arn as proof of a working edge."
  value       = var.wait_for_validation ? length(aws_acm_certificate_validation.this) > 0 : false
}

################################################################################
# Helm handoff
#
# NO txtOwnerId HERE, DELIBERATELY. products/lerian-platform/dns publishes one, and
# copying that shape would be the single most damaging thing this root could hand
# an operator during the migration.
#
# external-dns writes a TXT record beside every record it manages, stamped with
# txtOwnerId, and under `policy: sync` it will only delete what carries its own
# stamp. Both schemes are live at once for the whole migration, and the controller
# is still responsible for the records in the OLD zone. Re-stamping it with the new
# zone's id orphans every record in the old zone at once: nothing recognises them,
# so nothing cleans them up, and the cutover has no way to remove them.
#
# The owner id migrates once, explicitly, with --migrate-from-txt-owner and a
# dry-run first, in the cutover step — never as a side effect of a value an output
# offered.
################################################################################

output "helm_values" {
  description = <<-EOT
    Values the ingress layer needs from this zone. The certificate ARN goes on the
    Ingress annotation. No chart is installed by this root, and no txtOwnerId is
    published — see the comment above this output.

    THE DOMAIN FILTER IS INDEX 1, NOT 0, AND THAT IS COEXISTENCE-SPECIFIC. A Helm
    `--set` list key needs a zero-based index, and index 0 is already the old
    zone's filter, published by products/lerian-platform/dns. external-dns still
    has to write into that zone for the whole migration, so this value is ADDED
    beside it — a `--set` on index 0 would silently replace the filter for the
    zone that still carries every live record. At cutover, when the old zone's
    filter goes, this one becomes index 0.
  EOT

  value = {
    "external-dns.domainFilters[1]"                                       = aws_route53_zone.this.name
    "ingress.annotations.alb\\.ingress\\.kubernetes\\.io/certificate-arn" = aws_acm_certificate.this.arn
  }
}
