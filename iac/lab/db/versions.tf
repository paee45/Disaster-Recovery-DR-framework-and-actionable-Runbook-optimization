terraform {
  required_version = ">= 1.10"
  required_providers {
    aws   = { source = "hashicorp/aws", version = "~> 6.0" }
    local = { source = "hashicorp/local", version = "~> 2.5" }
  }
  # State lives in the S3 bucket from iac/platform/state-bucket (see backend.tf). It holds resource ids, not passwords
  # (RDS manages the master password in Secrets Manager).
}

provider "aws" {
  profile             = var.aws_profile
  region              = var.region
  allowed_account_ids = [var.account_id] # wrong account → Terraform refuses before doing anything
  default_tags { tags = { dr-lab = "true", managed-by = "terraform", repo-path = "iac/lab/aws" } }
}
