output "prefix" {
  description = "Name prefix for the product/environment pair: {product}-{environment}."
  value       = local.prefix
}

output "name" {
  description = "Fully qualified resource name: {product}-{environment}[-{component}]."
  value       = local.name
}

output "tags" {
  description = "Standard Lerian tag set merged with extra_tags."
  value       = local.tags
}
