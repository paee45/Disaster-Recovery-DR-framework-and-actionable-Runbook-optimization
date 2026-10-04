terraform {
  required_version = ">= 1.6"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 6.0" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
  # Local state (git-ignored). It holds the generated Terrakube admin password — keep it private.
}

provider "aws" {
  profile             = var.aws_profile
  region              = var.region
  allowed_account_ids = [var.account_id]
  default_tags { tags = { project = "dr-platform", managed-by = "terraform", repo-path = "iac/platform/terrakube" } }
}
