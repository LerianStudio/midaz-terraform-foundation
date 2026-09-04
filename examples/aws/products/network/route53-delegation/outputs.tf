################################################################################
# WHAT IS DELEGATED, FOR THE RECORD
#
# This output feeds no other root — the handoff runs one way and ends here. It
# exists so the evidence of an apply names the children that became resolvable,
# instead of asserting that "the delegation was created".
################################################################################

output "delegated_children" {
  description = "FQDNs of the child zones this root delegates from the parent. Each one has an NS record in the parent zone pointing at the name servers that child published."
  value       = keys(var.delegations)
}
