module "gke" {
  source  = "terraform-google-modules/kubernetes-engine/google//modules/beta-private-cluster"
  version = "~> 36.0"

  project_id = var.project_id
  name       = var.cluster_name
  region     = var.region

  // Resource labels
  cluster_resource_labels = {
    environment = var.environment
    managed_by  = "terraform"
  }

  deletion_protection = var.deletion_protection
  zones               = var.zones
  network             = var.network_name
  subnetwork          = var.subnet_name
  ip_range_pods       = var.ip_range_pods
  ip_range_services   = var.ip_range_services

  // Private cluster configuration
  enable_private_endpoint = var.enable_private_endpoint
  enable_private_nodes    = true
  master_ipv4_cidr_block  = var.master_ipv4_cidr_block

  // Master authorized networks
  master_authorized_networks = var.master_authorized_networks

  // Network policy
  network_policy = var.network_policy_enabled

  // Pod Security Configuration
  enable_pod_security_policy = var.pod_security_policy_enabled

  // Enable Pod Security Standards
  datapath_provider = var.datapath_provider
  release_channel   = var.release_channel # Required for Pod Security Standards

  // Node pools
  remove_default_node_pool = true

  node_pools = [
    {
      name               = "midaz-node-pool"
      machine_type       = var.machine_type
      min_count          = var.min_node_count
      max_count          = var.max_node_count
      disk_size_gb       = var.disk_size_gb
      disk_type          = var.node_disk_type
      image_type         = var.node_image_type
      auto_repair        = var.node_auto_repair
      auto_upgrade       = var.node_auto_upgrade
      preemptible        = var.node_preemptible
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
}