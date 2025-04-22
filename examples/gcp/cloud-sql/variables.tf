variable "project_id" {
  description = "The GCP project ID"
  type        = string
}

variable "instance_name" {
  description = "The name of the Cloud SQL instance"
  type        = string
  default     = "midaz-postgresql"
}

variable "region" {
  description = "The region for the Cloud SQL instance"
  type        = string
}

variable "zone" {
  description = "The zone for the Cloud SQL instance"
  type        = string
}

variable "instance_tier" {
  description = "The machine type for the Cloud SQL instance"
  type        = string
  default     = "db-custom-2-4096" # 2 vCPU, 4GB RAM
}

variable "disk_size" {
  description = "The disk size for the Cloud SQL instance in GB"
  type        = number
  default     = 100
}

variable "high_availability" {
  description = "Whether to enable high availability (regional) deployment"
  type        = bool
  default     = false
}

variable "backup_location" {
  description = "The backup location for the Cloud SQL instance"
  type        = string
  default     = "us-central1"
}

variable "vpc_self_link" {
  description = "The self link of the VPC network"
  type        = string
}

variable "environment" {
  description = "Environment name for resource labels"
  type        = string
  default     = "production"
}
