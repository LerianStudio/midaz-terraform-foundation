output "private_zone_id" {
  description = "ID of the private hosted zone"
  value       = aws_route53_zone.private.id
}

output "private_zone_name" {
  description = "Name of the private hosted zone"
  value       = aws_route53_zone.private.name
}
