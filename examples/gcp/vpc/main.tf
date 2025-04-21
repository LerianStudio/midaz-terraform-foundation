module "vpc" {
  source  = "terraform-google-modules/network/google"
  version = "~> 7.0"

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
