terraform {
  required_version = ">= 1.10, < 2.0"

  required_providers {
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.19.0"
    }
  }
}

provider "kubectl" {
  config_path       = var.config_path
  config_context    = "dr-local"
  load_config_file  = true
  apply_retry_count = 5
}