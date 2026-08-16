################################################################################
# Outputs
#
# Downstream stacks do NOT read this state with terraform_remote_state. They
# resolve the VPC by tag:Name (see the datastore modules in
# examples/aws/_modules), which is why vpc_name is exported: it is the exact
# string those lookups expect.
################################################################################

output "vpc_id" {
  description = "ID of the shared base VPC."
  value       = module.vpc.vpc_id
}

output "vpc_name" {
  description = "Name of the VPC, and the value of its Name tag. This is what every downstream module resolves with `data \"aws_vpc\"` filtered on tag:Name, so it is the identifier to pass as vpc_name to the datastore modules."
  value       = module.naming.name
}

output "vpc_cidr_block" {
  description = "Primary CIDR block of the VPC. Use it to build the ingress rules of anything that has to accept traffic from the whole VPC."
  value       = module.vpc.vpc_cidr_block
}

output "azs" {
  description = "Availability zones the subnets were created in, in the order the subnet lists follow."
  value       = module.vpc.azs
}

output "public_subnet_ids" {
  description = "IDs of the public subnets (tag Type=public). Internet-facing load balancers and the NAT Gateways live here."
  value       = module.vpc.public_subnets
}

output "private_subnet_ids" {
  description = "IDs of the private subnets (tag Type=private). EKS nodes and the interface VPC endpoints live here."
  value       = module.vpc.private_subnets
}

output "database_subnet_ids" {
  description = "IDs of the database subnets (tag Type=database). Every datastore module resolves these by tag rather than by this output."
  value       = module.vpc.database_subnets
}

output "cluster_name" {
  description = "Derived EKS cluster name written into the kubernetes.io/cluster/<name> subnet tags. The infra-base/eks stack MUST create its cluster with this exact name, otherwise the cluster cannot discover these subnets and load balancer provisioning fails."
  value       = local.cluster_name
}

output "nat_public_ips" {
  description = "Public IPs of the NAT Gateways. These are the source addresses this environment egresses from, which is what a third party allowlists (BACEN and partner rails included)."
  value       = module.vpc.nat_public_ips
}

output "private_route_table_ids" {
  description = "IDs of the private route tables. Needed to attach further gateway endpoints or transit gateway routes from another stack."
  value       = module.vpc.private_route_table_ids
}

output "database_route_table_ids" {
  description = "IDs of the route tables associated with the database subnets. Falls back to the private route tables when no dedicated database route table exists."
  value       = module.vpc.database_route_table_ids
}

output "vpc_endpoint_ids" {
  description = "Map of created VPC endpoints keyed by service short name (rds, secretsmanager, elasticache, s3, ...)."
  value       = { for key, endpoint in try(module.vpc_endpoints[0].endpoints, {}) : key => endpoint.id }
}

output "vpc_endpoint_security_group_id" {
  description = "ID of the security group attached to the interface VPC endpoints. Null when no interface endpoint was created."
  value       = one(aws_security_group.vpc_endpoints[*].id)
}
