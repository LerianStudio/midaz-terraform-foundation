# Azure region where resources will be created
variable "location" {
  description = "Azure region where resources will be created"
  type        = string
  default     = "eastus2"
}
variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default = {
    Environment = "Example"
    Terraform   = "true"
  }
}