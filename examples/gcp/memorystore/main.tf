module "memorystore" {
  source  = "terraform-google-modules/memorystore/google"
  version = "~> 7.0"

  name    = var.instance_name
  project = var.project_id
  region  = var.region

  tier               = var.high_availability ? "STANDARD_HA" : "BASIC"
  memory_size_gb     = var.memory_size_gb
  redis_version      = "REDIS_6_X"
  redis_configs      = var.redis_configs
  authorized_network = var.vpc_self_link
  connect_mode       = "PRIVATE_SERVICE_ACCESS"

  maintenance_policy = {
    day = "SUNDAY"
    start_time = {
      hours   = 23
      minutes = 0
      seconds = 0
      nanos   = 0
    }
  }

  labels = {
    environment = var.environment
    managed_by  = "terraform"
  }
}
