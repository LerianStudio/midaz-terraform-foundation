output "vpc_id" {
  description = "ID da VPC criada"
  value       = module.vpc.vpc_id
}

output "vpc_cidr_block" {
  description = "CIDR principal da VPC"
  value       = module.vpc.vpc_cidr_block
}

output "private_subnets" {
  description = "Subnets privadas"
  value       = module.vpc.private_subnets
}

output "public_subnets" {
  description = "Subnets públicas"
  value       = module.vpc.public_subnets
}

output "database_subnets" {
  description = "Subnets para banco de dados"
  value       = module.vpc.database_subnets
}

output "vpc_endpoint_rds_id" {
  description = "ID do VPC Endpoint para o serviço RDS"
  value       = try(module.vpc_endpoints[0].endpoints["rds"].id, null)
}

output "vpc_endpoint_secretsmanager_id" {
  description = "ID do VPC Endpoint para o serviço Secrets Manager"
  value       = try(module.vpc_endpoints[0].endpoints["secretsmanager"].id, null)
}

output "vpc_private_route_table_ids" {
  description = "IDs das route tables privadas"
  value       = module.vpc.private_route_table_ids
}

output "vpc_public_route_table_ids" {
  description = "IDs das route tables publicas"
  value       = module.vpc.public_route_table_ids
}