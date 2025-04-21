module "postgresql" {
  source  = "GoogleCloudPlatform/sql-db/google//modules/postgresql"
  version = "~> 15.0"

  name                 = var.instance_name
  random_instance_name = true
  project_id           = var.project_id
  database_version     = "POSTGRES_14"
  region               = var.region

  // Master configurations
  tier              = var.instance_tier
  zone              = var.zone
  availability_type = var.high_availability ? "REGIONAL" : "ZONAL"
  disk_size         = var.disk_size
  disk_type         = "PD_SSD"

  // Backup configurations
  backup_configuration = {
    enabled                        = true
    start_time                     = "23:00"
    location                       = var.backup_location
    point_in_time_recovery_enabled = var.high_availability
    transaction_log_retention_days = var.high_availability ? 7 : 1
    retained_backups               = var.high_availability ? 7 : 1
    retention_unit                 = "COUNT"
  }

  // Networking
  ip_configuration = {
    ipv4_enabled        = false
    private_network     = var.vpc_self_link
    require_ssl         = true
    allocated_ip_range  = null
    authorized_networks = []
  }

  // Database flags
  database_flags = [
    {
      name  = "max_connections"
      value = "100"
    }
  ]

  // Maintenance window
  maintenance_window_day          = 7  # Sunday
  maintenance_window_hour         = 23 # 11 PM
  maintenance_window_update_track = "stable"

  deletion_protection = true

  user_labels = {
    environment = var.environment
    managed_by  = "terraform"
  }
}
