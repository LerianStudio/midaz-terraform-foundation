################################################################################
# Derived cross-stack names
#
# Echoed rather than looked up: they are pure string derivations from
# var.environment, so they are known at plan time and are valid even when
# enabled = false. Callers pass them straight to their datastore module and
# re-export them, which is what lets `terraform output` assert the derivation
# without opening the tfvars.
################################################################################

output "vpc_name" {
  description = "tag:Name of the VPC, as derived or overridden. Should equal the vpc_name output of infra-base/vpc."
  value       = local.vpc_name
}

output "eks_cluster_name" {
  description = "EKS cluster whose node security group was looked up. Should equal the cluster_name output of infra-base/eks. Note the \"lerian\" prefix: the cluster belongs to infra-base, not to the product."
  value       = local.eks_cluster_name
}

################################################################################
# Resolved VPC facts
################################################################################

output "vpc_id" {
  description = "ID of the resolved VPC. Null when enabled is false."
  value       = one(data.aws_vpc.selected[*].id)
}

output "vpc_cidr_block" {
  description = "Primary CIDR block of the resolved VPC. Null when enabled is false. NOT used for ingress: it covers the public subnets too, which is exactly what private_subnet_cidr_blocks exists to avoid."
  value       = one(data.aws_vpc.selected[*].cidr_block)
}

output "private_subnet_cidr_blocks" {
  description = "CIDR blocks of the tag:Type = subnet_tag_type subnets, sorted. Empty when enabled or allow_private_subnet_cidr_ingress is false. Already folded into ingress_cidr_blocks — exposed separately for assertions and for callers that need the raw list."
  value       = local.private_subnet_cidrs
}

output "eks_node_security_group_ids" {
  description = "IDs of the EKS node security groups matched by tag:Name = \"{eks_cluster_name}-node\", sorted. Empty before infra-base/eks exists, which is the expected first-apply state — see check \"eks_node_security_group_resolved\". Already folded into ingress_security_group_ids."
  value       = local.eks_node_security_group_ids
}

################################################################################
# The ingress contract
#
# These two are the payload: a caller wires them straight into the
# allowed_security_group_ids / allowed_cidr_blocks of its datastore module.
################################################################################

output "ingress_security_group_ids" {
  description = "Security groups to authorise on the product's datastores: allowed_security_group_ids plus the EKS node security group. Empty before infra-base/eks exists unless allowed_security_group_ids was passed explicitly."
  value       = local.ingress_security_group_ids
}

output "ingress_cidr_blocks" {
  description = "CIDR blocks to authorise on the product's datastores: allowed_cidr_blocks plus the private subnet CIDRs while allow_private_subnet_cidr_ingress is true."
  value       = local.ingress_cidr_blocks
}
