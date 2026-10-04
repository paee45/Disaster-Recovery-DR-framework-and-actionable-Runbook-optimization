terraform {
  required_version = ">= 1.6"
  required_providers {
    aws   = { source = "hashicorp/aws", version = "~> 6.0" }
    local = { source = "hashicorp/local", version = "~> 2.5" }
  }
  # State stays on the operator's machine (git-ignored). It holds resource ids, not passwords (RDS manages the master
  # password in Secrets Manager). For a shared lab, move it to an S3 backend.
}

provider "aws" {
  profile             = var.aws_profile
  region              = var.region
  allowed_account_ids = [var.account_id] # wrong account → Terraform refuses before doing anything
  default_tags { tags = { dr-lab = "true", managed-by = "terraform", repo-path = "iac/lab/aws" } }
}
