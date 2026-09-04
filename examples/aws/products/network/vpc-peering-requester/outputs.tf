################################################################################
# THE CROSS-ACCOUNT HANDOFF
################################################################################

output "pcx_ids" {
  description = "Peering connection id per peer key. THIS IS THE INPUT THE OTHER ACCOUNT NEEDS: write each value into pcx_id in infra/envs/prd/products/network/vpc-peering-accepter/{stg,prd}.tfvars and apply the accepter root there. Until that happens each connection sits in pending-acceptance and carries no traffic, and it EXPIRES after 7 days."
  value       = { for key, peering in aws_vpc_peering_connection.this : key => peering.id }
}
