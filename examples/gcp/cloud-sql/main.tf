// Generate random password for database
resource "random_password" "postgres_password" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

// Create Secret Manager secrets
resource "google_secret_manager_secret" "postgres_user" {
  project   = var.project_id
  secret_id = "${var.instance_name}-postgres-user"

  replication {
    auto {}
  }

  labels = {
    environment = var.environment
    managed_by  = "terraform"
  }
}

resource "google_secret_manager_secret" "postgres_password" {
  project   = var.project_id
  secret_id = "${var.instance_name}-postgres-password"

  replication {
    auto {}
  }

  labels = {
    environment = var.environment
    managed_by  = "terraform"
  }
}

// Store the secrets: postgres
resource "google_secret_manager_secret_version" "postgres_user" {
  secret         = google_secret_manager_secret.postgres_user.id
  secret_data_wo = "postgres" // Default PostgreSQL admin username
}

resource "google_secret_manager_secret_version" "postgres_password" {
  secret         = google_secret_manager_secret.postgres_password.id
  secret_data_wo = random_password.postgres_password.result
}

// Generate password for the midaz user
resource "random_password" "midaz_user_password" {
  length  = 16
  special = true
  numeric = true
  upper   = true
  lower   = true
}

// Create Secret Manager secret for midaz user password
resource "google_secret_manager_secret" "midaz_user" {
  project   = var.project_id
  secret_id = "${var.instance_name}-midaz-user"

  replication {
    auto {}
  }

  labels = {
    environment = var.environment
    managed_by  = "terraform"
  }
}

resource "google_secret_manager_secret" "midaz_user_password" {
  project   = var.project_id
  secret_id = "${var.instance_name}-midaz-user-password"

  replication {
    auto {}
  }

  labels = {
    environment = var.environment
    managed_by  = "terraform"
  }
}

// Store the secrets: midaz
resource "google_secret_manager_secret_version" "midaz_user" {
  secret         = google_secret_manager_secret.midaz_user.id
  secret_data_wo = "midaz" // Default PostgreSQL admin username
}

resource "google_secret_manager_secret_version" "midaz_user_password" {
  secret         = google_secret_manager_secret.midaz_user_password.id
  secret_data_wo = random_password.midaz_user_password.result
}

module "postgresql" {
  source  = "GoogleCloudPlatform/sql-db/google//modules/postgresql"
  version = "~> 25.0"

  // Read replica configuration
  read_replicas = var.high_availability ? [
    {
      name                  = "replica"
      name_override         = "${var.instance_name}-read-replica"
      tier                  = var.instance_tier
      zone                  = "${var.region}-b"
      availability_type     = "REGIONAL"
      disk_type             = var.disk_type
      disk_size             = var.disk_size
      disk_autoresize       = var.disk_autoresize
      disk_autoresize_limit = var.disk_autoresize_limit
      edition               = "ENTERPRISE"
      user_labels = {
        environment = var.environment
        managed_by  = "terraform"
        replica     = "true"
      }
      database_flags = []
      ip_configuration = {
        ipv4_enabled        = false
        private_network     = var.vpc_self_link
        require_ssl         = false #tfsec:ignore:google-sql-encrypt-in-transit-data
        allocated_ip_range  = null
        authorized_networks = []
      }
      encryption_key_name = null
    }
  ] : []

  name                 = var.instance_name
  random_instance_name = false
  project_id           = var.project_id
  database_version     = var.db_version
  user_password        = random_password.postgres_password.result
  region               = var.region
  edition              = "ENTERPRISE"

  // Create additional databases
  additional_databases = [
    {
      name      = "onboarding"
      charset   = var.db_charset
      collation = var.db_collation
    },
    {
      name      = "transaction"
      charset   = var.db_charset
      collation = var.db_collation
    }
  ]

  // Create additional users
  additional_users = [
    {
      name            = "midaz"
      password        = random_password.midaz_user_password.result
      random_password = false
      host            = "%"
      type            = "BUILT_IN"
    }
  ]

  // Master configurations
  tier              = var.instance_tier
  zone              = var.zone
  availability_type = var.high_availability ? "REGIONAL" : "ZONAL"
  disk_size         = var.disk_size
  disk_type         = var.disk_type

  // Backup configurations
  backup_configuration = {
    enabled                        = true
    start_time                     = var.backup_start_time
    location                       = var.backup_location
    point_in_time_recovery_enabled = var.high_availability
    transaction_log_retention_days = var.high_availability ? 7 : 1
    retained_backups               = var.high_availability ? 14 : 3
    retention_unit                 = var.backup_retention_unit
  }

  // Networking
  ip_configuration = {
    ipv4_enabled        = false
    private_network     = var.vpc_self_link
    require_ssl         = false
    allocated_ip_range  = null
    authorized_networks = []
  }

  // Database flags
  database_flags = [
    {
      name  = "max_connections"
      value = var.max_connections
    },
    {
      name  = "log_checkpoints"
      value = var.log_checkpoints
    },
    {
      name  = "log_connections"
      value = var.log_connections
    },
    {
      name  = "log_disconnections"
      value = var.log_disconnections
    },
    {
      name  = "log_lock_waits"
      value = var.log_lock_waits
    },
    {
      name  = "log_temp_files"
      value = var.log_temp_files
    }
  ]

  // Maintenance window
  maintenance_window_day          = var.maintenance_window_day
  maintenance_window_hour         = var.maintenance_window_hour
  maintenance_window_update_track = var.maintenance_window_update_track

  deletion_protection = var.deletion_protection

  user_labels = {
    environment = var.environment
    managed_by  = "terraform"
  }
}

// Create DNS A record for the database
resource "google_dns_record_set" "database" {
  project      = var.project_id
  name         = "postgresql.${data.google_dns_managed_zone.private_zone.dns_name}"
  managed_zone = data.google_dns_managed_zone.private_zone.name
  type         = "A"
  ttl          = 300

  rrdatas = [module.postgresql.private_ip_address]
}

// Create DNS A record for the read replica when high_availability is enabled
resource "google_dns_record_set" "database_replica" {
  count        = var.high_availability ? 1 : 0
  project      = var.project_id
  name         = "postgresql-replica.${data.google_dns_managed_zone.private_zone.dns_name}"
  managed_zone = data.google_dns_managed_zone.private_zone.name
  type         = "A"
  ttl          = 300

  rrdatas = [module.postgresql.replicas[0].private_ip_address]
}
