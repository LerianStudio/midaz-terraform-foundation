terraform {
  backend "gcs" {
    bucket = "<PUT-YOUR-GCS-BUCKET-NAME-HERE>"
    prefix = "gcp/memorystore"
  }
}
