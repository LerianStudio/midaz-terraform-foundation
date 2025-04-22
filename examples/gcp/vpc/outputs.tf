output "network_name" {
  description = "The name of the VPC network"
  value       = module.vpc.network_name
}

output "network_id" {
  description = "The ID of the VPC network"
  value       = module.vpc.network_id
}

output "subnet_name" {
  description = "The name of the subnet"
  value       = module.vpc.subnets_names[0]
}

output "subnet_id" {
  description = "The ID of the subnet"
  value       = module.vpc.subnets_ids[0]
}

output "subnet_secondary_ranges" {
  description = "The secondary ranges associated with the subnet"
  value       = module.vpc.subnets_secondary_ranges
}
