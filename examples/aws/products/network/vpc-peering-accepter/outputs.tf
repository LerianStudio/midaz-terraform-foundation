################################################################################
# WHAT WAS ACCEPTED, FOR THE RECORD
#
# Neither output feeds another root — the cross-account handoff runs one way and
# ends here. They exist so the evidence of an apply names the connection and the
# block it routes, instead of asserting that a peering "was accepted".
################################################################################

output "accepted_pcx_id" {
  description = "Id of the peering connection this environment accepted. Matches one value of pcx_ids from products/network/vpc-peering-requester in the control-plane account."
  value       = aws_vpc_peering_connection_accepter.this.vpc_peering_connection_id
}

output "peer_cidr" {
  description = "Remote CIDR block now routed from this VPC over the peering — the control plane, 10.59.0.0/16. Echoed back so an apply's evidence shows which block was routed, on which side, rather than only that a peering exists."
  value       = var.peer_cidr
}
