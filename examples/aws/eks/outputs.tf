output "cluster_id" {
  description = "EKS cluster ID"
  value       = module.eks.cluster_id
}

output "cluster_endpoint" {
  description = "Endpoint for EKS control plane"
  value       = module.eks.cluster_endpoint
}

output "cluster_security_group_id" {
  description = "Security group IDs attached to the cluster control plane"
  value       = module.eks.cluster_security_group_id
}

output "cluster_iam_role_name" {
  description = "IAM role name of the EKS cluster"
  value       = module.eks.cluster_iam_role_name
}

output "eks_managed_node_groups" {
  description = "EKS managed node groups"
  value       = module.eks.eks_managed_node_groups
}

output "admin_role_arn" {
  description = "ARN of the admin IAM role"
  value       = aws_iam_role.admin_role.arn
}

output "developer_role_arn" {
  description = "ARN of the developer IAM role"
  value       = aws_iam_role.developer_role.arn
}

output "ebs_csi_role_arn" {
  description = "ARN of the EBS CSI driver IAM role"
  value       = module.ebs_csi_irsa_role.iam_role_arn
}

output "cluster_autoscaler_role_arn" {
  description = "ARN of the cluster autoscaler IAM role"
  value       = try(module.cluster_autoscaler_irsa_role[0].iam_role_arn, "")
}

output "load_balancer_controller_role_arn" {
  description = "ARN of the AWS Load Balancer Controller IAM role"
  value       = try(module.aws_load_balancer_controller_irsa_role[0].iam_role_arn, "")
}
