terraform {
  required_version = ">= 1.6.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.45"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
    # Phase 2 will use gavinbunney/kubectl for SandboxTemplate / WarmPool /
    # NetworkPolicy / router manifests. Declared here so init pre-fetches it.
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
    # Phase 5: hashicorp/kubernetes is used as a READ-ONLY data source to
    # pull the internal-LB IP of sandbox-router-internal (so the Cloud
    # Run bridge env var doesn't have to be hardcoded). All WRITES still
    # go through kubectl (which handles CRDs).
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
  }

  backend "gcs" {
    bucket = "cpe-slarbi-nvd-ant-demos-tfstate"
    prefix = "cc-on-ge"
  }
}
