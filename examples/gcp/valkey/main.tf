// Get the DNS zone data
data "google_dns_managed_zone" "private_zone" {
  name    = "midaz-private-dns"
  project = var.project_id
}

module "memorystore_valkey" {
  source = "terraform-google-modules/memorystore/google//modules/valkey"

  project_id  = var.project_id
  instance_id = var.instance_name
  location    = var.region

  # Valkey cluster settings
  replica_count = var.replica_count
  shard_count   = var.shard_count
  node_type     = var.node_type # High memory for better performance

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
  rrdatas      = [module.memorystore_valkey.valkey_cluster.discovery_endpoints[0].address]
}

# Create service account for Valkey authentication
resource "google_service_account" "valkey_auth" {
  project      = var.project_id
  account_id   = "${var.instance_name}-auth"
  display_name = "Service Account for ${var.instance_name} Valkey Authentication"

  description = "Service account used for Valkey IAM authentication"
}

# Grant the required Memorystore DB Connection User role
resource "google_project_iam_member" "valkey_auth_role" {
  project = var.project_id
  role    = "roles/memorystore.dbConnectionUser"
  member  = "serviceAccount:${google_service_account.valkey_auth.email}"
}

# Store service account key in Secret Manager for applications to use
resource "google_secret_manager_secret" "valkey_auth" {
  project   = var.project_id
  secret_id = "${var.instance_name}-auth-sa"

  replication {
    auto {}
  }

  labels = {
    environment = var.environment
    managed_by  = "terraform"
    type        = "valkey"
  }
}

# Create and store service account key
resource "google_service_account_key" "valkey_auth" {
  service_account_id = google_service_account.valkey_auth.name
}

resource "google_secret_manager_secret_version" "valkey_auth" {
  secret         = google_secret_manager_secret.valkey_auth.id
  secret_data_wo = base64decode(google_service_account_key.valkey_auth.private_key)
}
