# Primary RDS DNS record
resource "aws_route53_record" "db" {
  zone_id = data.aws_route53_zone.selected.zone_id
  name    = "${var.name}.${var.dns_zone_name}"
  type    = "CNAME"
  ttl     = 300
  records = [module.db.db_instance_address]
}

# Read replica DNS record (if enabled)
resource "aws_route53_record" "db_replica" {
  count   = var.create_read_replica ? 1 : 0
  zone_id = data.aws_route53_zone.selected.zone_id
  name    = "${var.name}-replica.${var.dns_zone_name}"
  type    = "CNAME"
  ttl     = 300
  records = [module.db_replica[0].db_instance_address]
}
