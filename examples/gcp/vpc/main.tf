module "vpc" {
  source  = "terraform-google-modules/network/google"
  version = "~> 11.0"

  project_id   = var.project_id
  network_name = var.network_name
  routing_mode = "GLOBAL"

  subnets = [
    {
      subnet_name           = "${var.network_name}-subnet"
      subnet_ip             = var.subnet_cidr
      subnet_region         = var.region
      subnet_private_access = true
    }
  ]

  secondary_ranges = {
    "${var.network_name}-subnet" = [
      {
        range_name    = "pods"
        ip_cidr_range = var.pods_cidr_range
      },
      {
        range_name    = "services"
        ip_cidr_range = var.services_cidr_range
      }
    ]
  }
}

# Create Cloud Router
resource "google_compute_router" "router" {
  name    = "${var.network_name}-router"
  region  = var.region
  network = module.vpc.network_name
  project = var.project_id
}

# Create NAT configuration
resource "google_compute_router_nat" "nat" {
  name                               = "${var.network_name}-nat"
  router                             = google_compute_router.router.name
  region                             = var.region
  project                            = var.project_id
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

// Reserve global IP range for private services
resource "google_compute_global_address" "private_service_range" {
  project       = var.project_id
  name          = "google-managed-services-${var.network_name}"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = module.vpc.network_name
}

// Create service networking connection for private services
resource "google_service_networking_connection" "private_service_connection" {
  network                 = module.vpc.network_self_link
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_service_range.name]
}

resource "google_project_service" "compute" {
  project = var.project_id
  service = "compute.googleapis.com"

  disable_dependent_services = false
  disable_on_destroy         = false
}

resource "google_project_service" "service_networking" {
  project = var.project_id
  service = "servicenetworking.googleapis.com"

  disable_dependent_services = false
  disable_on_destroy         = false
}