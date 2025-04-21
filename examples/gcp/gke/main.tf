module "gke" {
  source  = "terraform-google-modules/kubernetes-engine/google//modules/beta-private-cluster"
  version = "~> 25.0"

  project_id = var.project_id
  name       = var.cluster_name
  region     = var.region

  // Resource labels
  cluster_resource_labels = {
    environment = var.environment
    managed_by  = "terraform"
  }
  zones             = var.zones
  network           = var.network_name
  subnetwork        = var.subnet_name
  ip_range_pods     = "pods"
  ip_range_services = "services"

  // Private cluster configuration
  enable_private_endpoint = var.enable_private_endpoint
  enable_private_nodes    = true
  master_ipv4_cidr_block  = var.master_ipv4_cidr_block

  // Master authorized networks
  master_authorized_networks = [
    {
      cidr_block   = "10.0.0.0/8"
      display_name = "internal-vpc"
    }
  ]

  // Security configurations
  enable_pod_security_policy = true

  // Network policy
  network_policy = true

  // Node pools
  node_pools = [
    {
      name               = "default-node-pool"
      machine_type       = var.machine_type
      min_count          = var.min_node_count
      max_count          = var.max_node_count
      disk_size_gb       = var.disk_size_gb
      disk_type          = "pd-ssd"
      image_type         = "COS_CONTAINERD"
      auto_repair        = true
      auto_upgrade       = true
      service_account    = var.service_account
      preemptible        = false
      initial_node_count = var.initial_node_count
    }
  ]

  node_pools_oauth_scopes = {
    all = [
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring",
      "https://www.googleapis.com/auth/devstorage.read_only"
    ]
  }

  node_pools_labels = {
    all = {
      environment = var.environment
      managed_by  = "terraform"
    }
  }

  node_pools_metadata = {
    all = {
      disable-legacy-endpoints = "true"
    }
  }

  node_pools_tags = {
    all = ["gke-${var.cluster_name}"]
  }
}
