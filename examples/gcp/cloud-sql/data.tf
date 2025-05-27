// Get the DNS zone data
data "google_dns_managed_zone" "private_zone" {
  name    = "midaz-private-dns"
  project = var.project_id
}
