terraform {
  required_version = ">= 1.10, < 2.0"

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35.0"
    }
  }
}

provider "kubernetes" {
  config_path    = var.config_path
  config_context = "dr-local"
}

provider "helm" {
  kubernetes {
    config_path    = var.config_path
    config_context = "dr-local"
  }
}