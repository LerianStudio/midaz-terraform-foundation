module "memorystore_valkey" {
  source  = "terraform-google-modules/memorystore/google//modules/valkey"
  version = "~> 14.0"

  project_id  = var.project_id
  instance_id = var.instance_name
  location    = var.region

  # Valkey cluster settings
  replica_count                 = var.replica_count
  shard_count                   = var.shard_count
  node_type                     = var.node_type # High memory for better performance
  mode                          = var.mode
  zone_distribution_config_mode = var.zone_distribution_config_mode
  zone_distribution_config_zone = var.zone_distribution_config_mode == "SINGLE_ZONE" ? var.zone_distribution_config_zone : null

  # Engine configuration
  engine_version              = var.engine_version
  deletion_protection_enabled = var.deletion_protection_enabled

  # Authorization mode
  authorization_mode = var.authorization_mode

  # Network configuration
  network = var.vpc_self_link
  service_connection_policies = {
    "${var.instance_name}-scp" = {
      subnet_names = [var.subnet_name]
    }
  }

  # Persistence configuration
  persistence_config = {
    mode = "RDB"
    rdb_config = {
      snapshot_period_seconds = var.snapshot_period_seconds # Default: 12 hours
    }
  }

  # Labels
  labels = {
    environment = var.environment
    managed_by  = "terraform"
    type        = "valkey"
    version     = "8"
  }

}

// Create DNS record for Valkey instance
resource "google_dns_record_set" "valkey" {
  project      = var.project_id
  name         = "valkey.${data.google_dns_managed_zone.private_zone.dns_name}"
  managed_zone = data.google_dns_managed_zone.private_zone.name
  type         = "A"
  ttl          = 300
  rrdatas      = var.mode == "CLUSTER" ? [try(module.memorystore_valkey.valkey_cluster.discovery_endpoints[0].address, "")] : [try(module.memorystore_valkey.valkey_cluster.endpoints[0].connections[0].psc_auto_connection[0].ip_address, "")]
}
