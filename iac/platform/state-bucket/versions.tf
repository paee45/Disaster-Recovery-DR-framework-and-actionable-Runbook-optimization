terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
  # Bootstrap: iac/tf.sh first runs this stack on a local backend (it creates the bucket), then moves its own state
  # into that bucket (key platform/shared/state-bucket). prevent_destroy guards the bucket; never destroy it while
  # other stacks keep their state in it.
}

provider "aws" {
  profile             = var.aws_profile
  region              = var.region
  allowed_account_ids = [var.account_id]
  default_tags { tags = { project = "dr-platform", managed-by = "terraform", repo-path = "iac/platform/state-bucket" } }
}
