terraform {
  required_version = ">= 1.6.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.45"
    }
  }

  # Bootstrap uses a LOCAL backend because it creates the bucket that the
  # main root will then use as its remote backend. Do not change to gcs.
  backend "local" {}
}
