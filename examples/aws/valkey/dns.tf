# DNS Record
data "aws_route53_zone" "selected" {
  name         = var.dns_zone_name
  private_zone = true
}

resource "aws_route53_record" "valkey" {
  zone_id = data.aws_route53_zone.selected.zone_id
  name    = "${var.dns_name}.${var.dns_zone_name}"
  type    = "CNAME"
  ttl     = 300
  records = [module.valkey.replication_group_primary_endpoint_address]
}
