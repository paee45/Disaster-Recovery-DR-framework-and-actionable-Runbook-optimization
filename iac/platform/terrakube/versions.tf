terraform {
  required_version = ">= 1.10"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 6.0" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
  # State lives in the S3 bucket from iac/platform/state-bucket (see backend.tf). It holds the generated Terrakube
  # admin password — the bucket is private + encrypted; keep access tight. Never store this stack's state IN Terrakube.
}

provider "aws" {
  profile             = var.aws_profile
  region              = var.region
  allowed_account_ids = [var.account_id]
  default_tags { tags = { project = "dr-platform", managed-by = "terraform", repo-path = "iac/platform/terrakube" } }
}
