terraform {
  required_version = ">= 1.10"
  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 6.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.35" }
    helm       = { source = "hashicorp/helm", version = "~> 2.17" }
  }
}

# Cluster details come from the eks stack (apply that first). Separate stacks so the Kubernetes provider is never
# configured before the cluster exists.
data "terraform_remote_state" "eks" {
  backend = "s3"
  config = {
    bucket  = var.state_bucket
    key     = "lab/shared/eks/terraform.tfstate"
    region  = var.region
    profile = var.aws_profile
  }
}

locals {
  eks = data.terraform_remote_state.eks.outputs
}

provider "aws" {
  profile             = var.aws_profile
  region              = var.region
  allowed_account_ids = [var.account_id]
  default_tags { tags = { dr-lab = "true", managed-by = "terraform", repo-path = "iac/lab/addons" } }
}

# Short-lived token from the AWS provider — no aws CLI needed (works on a Mac and inside the Terrakube executor).
data "aws_eks_cluster_auth" "this" {
  name = local.eks.eks_cluster_name
}

provider "kubernetes" {
  host                   = local.eks.eks_endpoint
  cluster_ca_certificate = base64decode(local.eks.eks_ca)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = local.eks.eks_endpoint
    cluster_ca_certificate = base64decode(local.eks.eks_ca)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}
