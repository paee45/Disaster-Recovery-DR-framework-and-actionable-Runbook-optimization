terraform {
  required_version = ">= 1.10"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 6.0" }
    random = { source = "hashicorp/random", version = "~> 3.0" }
  }
}

provider "aws" {
  profile             = var.aws_profile
  region              = var.region
  allowed_account_ids = [var.account_id]
  default_tags {
    tags = {
      dr-lab      = "true"
      managed-by  = "terraform"
      repo-path   = "iac/lab/bb3-db"
      dr-env      = var.env
      Environment = var.env
      app         = "bb3-sandbox"
    }
  }
}

data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket              = var.state_bucket
    key                 = "lab/shared/network/terraform.tfstate"
    region              = var.region
    profile             = var.aws_profile
    allowed_account_ids = [var.account_id]
  }
}

locals {
  net    = data.terraform_remote_state.network.outputs
  prefix = "dr-sandbox-bb3-${var.env}"
}