terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
  # Bootstrap stack: it creates the bucket the other stacks keep their state in, so ITS OWN state stays local
  # (git-ignored, tiny, no secrets). Never destroy it while other stacks still store state in the bucket.
}

provider "aws" {
  profile             = var.aws_profile
  region              = var.region
  allowed_account_ids = [var.account_id]
  default_tags { tags = { project = "dr-platform", managed-by = "terraform", repo-path = "iac/platform/state-bucket" } }
}
