terraform {
  required_version = ">= 1.6"
  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 6.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.35" }
    helm       = { source = "hashicorp/helm", version = "~> 2.17" }
    random     = { source = "hashicorp/random", version = "~> 3.6" }
    local      = { source = "hashicorp/local", version = "~> 2.5" }
  }
}

# Everything about the cluster/DB comes from the aws stack (apply that first). Separate stacks so the Kubernetes
# provider is never configured before the cluster exists.
data "terraform_remote_state" "aws" {
  backend = "local"
  config  = { path = "${path.module}/../aws/terraform.tfstate" }
}

locals {
  a = data.terraform_remote_state.aws.outputs
}

provider "aws" {
  profile             = local.a.aws_profile == "" ? null : local.a.aws_profile
  region              = local.a.region
  allowed_account_ids = [local.a.account_id]
  default_tags { tags = { dr-lab = "true", managed-by = "terraform", repo-path = "iac/lab/k8s" } }
}

# Short-lived token from the AWS provider — no aws CLI needed (works on a Mac and inside the Terrakube executor).
data "aws_eks_cluster_auth" "this" {
  name = local.a.eks_cluster_name
}

provider "kubernetes" {
  host                   = local.a.eks_endpoint
  cluster_ca_certificate = base64decode(local.a.eks_ca)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = local.a.eks_endpoint
    cluster_ca_certificate = base64decode(local.a.eks_ca)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}
