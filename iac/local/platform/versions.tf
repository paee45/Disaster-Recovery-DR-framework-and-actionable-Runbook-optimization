terraform {
  backend "local" {}
  required_version = ">= 1.15.2, < 2.0.0"
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "3.6.2"
    }
  }
}

provider "docker" {
  host = var.docker_host
}