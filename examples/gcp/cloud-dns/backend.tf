terraform {
  backend "gcs" {
    bucket = "<YOUR-TERRAFORM-STATE-BUCKET>"
    prefix = "gcp/cloud-dns"
  }
}
