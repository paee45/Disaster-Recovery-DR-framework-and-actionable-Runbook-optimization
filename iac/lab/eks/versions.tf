terraform {
  required_version = ">= 1.10"
  required_providers {
    aws   = { source = "hashicorp/aws", version = "~> 6.0" }
    local = { source = "hashicorp/local", version = "~> 2.5" }
  }
}

provider "aws" {
  profile             = var.aws_profile
  region              = var.region
  allowed_account_ids = [var.account_id]
  default_tags { tags = { dr-lab = "true", managed-by = "terraform", repo-path = "iac/lab/eks" } }
}

# VPC and subnets come from the network stack (apply that first).
data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket  = var.state_bucket
    key     = "lab/shared/network/terraform.tfstate"
    region  = var.region
    profile = var.aws_profile
  }
}

locals {
  subnet_ids = data.terraform_remote_state.network.outputs.public_subnet_ids
}
