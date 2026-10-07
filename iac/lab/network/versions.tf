terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

provider "aws" {
  profile             = var.aws_profile
  region              = var.region
  allowed_account_ids = [var.account_id] # wrong account → Terraform refuses before doing anything
  default_tags { tags = { dr-lab = "true", managed-by = "terraform", repo-path = "iac/lab/network" } }
}
