module "dns-private-zone" {
  source  = "terraform-google-modules/cloud-dns/google"
  version = "~> 5.0"

  project_id = var.project_id
  type       = "private"
  name       = var.dns_name
  domain     = var.dns_domain

  private_visibility_config_networks = [var.vpc_self_link]

  recordsets = var.record_sets
}
