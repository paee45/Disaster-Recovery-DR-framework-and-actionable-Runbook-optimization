terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
  # One state per env (iac/tf.sh lab/db <env> ...). It holds resource ids, not passwords
  # (RDS manages the master password in Secrets Manager).
}

provider "aws" {
  profile             = var.aws_profile
  region              = var.region
  allowed_account_ids = [var.account_id] # wrong account → Terraform refuses before doing anything
  default_tags { tags = { dr-lab = "true", managed-by = "terraform", repo-path = "iac/lab/db", dr-env = var.env } }
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
  net = data.terraform_remote_state.network.outputs
}
