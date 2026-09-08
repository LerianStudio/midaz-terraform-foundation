output "mode" {
  description = "Published as a constant so `terraform output mode` answers uniformly across every root. A hosted zone has no shared tier."
  value       = "dedicated"
}

################################################################################
# THE MANUAL STEP
################################################################################

output "name_servers" {
  description = "THE FOUR NAME SERVERS THE PARENT ACCOUNT MUST DELEGATE TO. Create one NS record named `{zone_name}.` in the parent zone, in the OTHER account, with these four values and a TTL of 300. That record is the only point of contact between the two accounts, and nothing on this estate resolves publicly until it exists — including the ACM validation this same apply is waiting on."
  value       = aws_route53_zone.this.name_servers
}

output "delegation_instruction" {
  description = "The manual step, spelled out, so it can be pasted into a runbook or a ticket without anybody having to reconstruct it from the other outputs."
  value = format(
    "In the account holding %s, create an NS record for '%s.' with TTL 300 and these values: %s",
    var.parent_zone_name,
    var.zone_name,
    join(", ", aws_route53_zone.this.name_servers),
  )
}

################################################################################
# Zone
################################################################################

output "zone_id" {
  description = "Hosted zone id. external-dns and cert-manager IAM policies scope to arn:aws:route53:::hostedzone/{this} — narrowing them from the wildcard the foundation's prd example ships is the reason this output exists."
  value       = aws_route53_zone.this.zone_id
}

output "zone_arn" {
  description = "Hosted zone ARN, ready to paste into external_dns_hosted_zone_arns and cert_manager_hosted_zone_arns in the infra-base/eks tfvars. THOSE TWO DEFAULT TO arn:aws:route53:::hostedzone/* AND THE prd EXAMPLE KEEPS THE WILDCARD — in the one environment where both roles are enabled. Narrow them to this value."
  value       = "arn:aws:route53:::hostedzone/${aws_route53_zone.this.zone_id}"
}

output "zone_name" {
  description = "Name of the zone. This is also the --domain-filter external-dns must be given: without it the controller considers every zone the role can reach."
  value       = aws_route53_zone.this.name
}

################################################################################
# Certificate
################################################################################

output "certificate_arn" {
  description = "ARN of the wildcard certificate. Goes on every Ingress as alb.ingress.kubernetes.io/certificate-arn. Reading this output does NOT mean the certificate is usable — check certificate_validated."
  value       = aws_acm_certificate.this.arn
}

output "certificate_domains" {
  description = "Names the certificate covers: the apex and one wildcard label. It matches gw.{zone} and does NOT match a.b.{zone} — a wildcard covers exactly one label."
  # distinct(): some provider versions report domain_name inside
  # subject_alternative_names, and a duplicated apex here reads as a second
  # certificate name that does not exist.
  value = distinct(concat([aws_acm_certificate.this.domain_name], tolist(aws_acm_certificate.this.subject_alternative_names)))
}

output "certificate_validated" {
  description = "Whether this apply actually waited for and observed successful validation. FALSE means either wait_for_validation was turned off or the wait has not run: the certificate exists, is ISSUED-pending, and an ALB listener referencing it will not serve TLS. Do not read certificate_arn as proof of a working edge."
  value       = var.wait_for_validation ? length(aws_acm_certificate_validation.this) > 0 : false
}

################################################################################
# Helm handoff
################################################################################

output "helm_values" {
  description = "Values the ingress layer needs. The certificate ARN goes on the Ingress annotation; the domain filter scopes external-dns to this zone only. No chart is installed by this root."
  value = {
    "external-dns.domainFilters[0]"                                       = aws_route53_zone.this.name
    "external-dns.txtOwnerId"                                             = aws_route53_zone.this.zone_id
    "ingress.annotations.alb\\.ingress\\.kubernetes\\.io/certificate-arn" = aws_acm_certificate.this.arn
  }
}
