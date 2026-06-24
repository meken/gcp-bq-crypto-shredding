variable "project_id" {
  type        = string
  description = "The GCP Project ID where resources will be created"
}

variable "region" {
  type        = string
  description = "The GCP region for provider level configuration"
  default     = "us-central1"
}

variable "location" {
  type        = string
  description = "The multi-region or regional location for the BigQuery dataset and tables"
  default     = "US"
}

variable "dataset_id" {
  type        = string
  description = "The ID of the BigQuery dataset to be created"
  default     = "crypto_shredding_demo"
}
