################################################################################
# Cluster identity
################################################################################

output "cluster_name" {
  description = "EKS cluster name, {product}-{environment}-eks. Must match the kubernetes.io/cluster/<name> subnet tags set by the infra-base/vpc stack."
  value       = module.eks.cluster_name
}

output "cluster_arn" {
  description = "ARN of the EKS cluster."
  value       = module.eks.cluster_arn
}

output "cluster_version" {
  description = "Kubernetes version running on the control plane."
  value       = module.eks.cluster_version
}

output "cluster_endpoint" {
  description = "Kubernetes API server endpoint."
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded cluster CA certificate, for kubeconfig or in-cluster clients."
  value       = module.eks.cluster_certificate_authority_data
}

################################################################################
# Networking
################################################################################

output "vpc_id" {
  description = "ID of the VPC the cluster runs in."
  value       = data.aws_vpc.selected.id
}

output "subnet_ids" {
  description = "Subnets where nodes and control plane ENIs are placed."
  value       = data.aws_subnets.selected.ids
}

output "cluster_security_group_id" {
  description = "Security group created by the module for the control plane."
  value       = module.eks.cluster_security_group_id
}

output "cluster_primary_security_group_id" {
  description = "Primary security group created by the EKS service. Datastore modules allow ingress from this group so pods can reach RDS/DocumentDB/Valkey."
  value       = module.eks.cluster_primary_security_group_id
}

output "node_security_group_id" {
  description = "Shared security group attached to the managed node groups."
  value       = module.eks.node_security_group_id
}

################################################################################
# IRSA
#
# oidc_provider_arn is what other stacks (for example the s3-bucket module) need
# to mint IRSA roles against this cluster.
################################################################################

output "oidc_provider_arn" {
  description = "ARN of the cluster IAM OIDC provider. Pass this to iam-role-for-service-accounts-eks style modules to create IRSA roles."
  value       = module.eks.oidc_provider_arn
}

output "oidc_provider_url" {
  description = "Full OIDC issuer URL of the cluster (https://oidc.eks.<region>.amazonaws.com/id/<id>)."
  value       = module.eks.cluster_oidc_issuer_url
}

output "oidc_provider" {
  description = "OIDC issuer without the https:// scheme, the form used in IAM trust policy condition keys (<issuer>:sub)."
  value       = module.eks.oidc_provider
}

################################################################################
# Encryption
################################################################################

output "kms_key_arn" {
  description = "ARN of the CMK used for envelope encryption of Kubernetes secrets."
  value       = module.eks_kms_key.key_arn
}

output "kms_key_id" {
  description = "ID of the CMK used for envelope encryption of Kubernetes secrets."
  value       = module.eks_kms_key.key_id
}

################################################################################
# IAM roles
################################################################################

output "admin_role_arn" {
  description = "ARN of the cluster administrator role (AmazonEKSClusterAdminPolicy). Assume it before running kubectl."
  value       = aws_iam_role.admin_role.arn
}

output "developer_role_arn" {
  description = "ARN of the developer role (AmazonEKSViewPolicy, read-only)."
  value       = aws_iam_role.developer_role.arn
}

output "cluster_iam_role_arn" {
  description = "IAM role ARN of the EKS control plane."
  value       = module.eks.cluster_iam_role_arn
}

output "ebs_csi_role_arn" {
  description = "IRSA role ARN used by the aws-ebs-csi-driver addon."
  value       = module.ebs_csi_irsa_role.iam_role_arn
}

output "cluster_autoscaler_role_arn" {
  description = "IRSA role ARN for the Cluster Autoscaler service account, empty when create_autoscaler_role is false."
  value       = try(module.cluster_autoscaler_irsa_role[0].iam_role_arn, "")
}

output "load_balancer_controller_role_arn" {
  description = "IRSA role ARN for the AWS Load Balancer Controller service account, empty when create_load_balancer_controller_role is false."
  value       = try(module.aws_load_balancer_controller_irsa_role[0].iam_role_arn, "")
}

output "external_dns_role_arn" {
  description = "IRSA role ARN for the ExternalDNS service account, empty when create_external_dns_role is false."
  value       = try(module.external_dns_irsa_role[0].iam_role_arn, "")
}

output "cert_manager_role_arn" {
  description = "IRSA role ARN for the cert-manager service account, empty when create_cert_manager_role is false."
  value       = try(module.cert_manager_irsa_role[0].iam_role_arn, "")
}

################################################################################
# Node groups
################################################################################

output "node_group_names" {
  description = "Names of the managed node groups created."
  value       = [for k, ng in module.eks.eks_managed_node_groups : ng.node_group_id]
}

output "node_group_iam_role_arns" {
  description = "Map of node group key to node IAM role ARN."
  value       = { for k, ng in module.eks.eks_managed_node_groups : k => ng.iam_role_arn }
}

################################################################################
# Convenience
################################################################################

output "update_kubeconfig" {
  description = "Ready to run command that writes this cluster into the local kubeconfig."
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}"
}
