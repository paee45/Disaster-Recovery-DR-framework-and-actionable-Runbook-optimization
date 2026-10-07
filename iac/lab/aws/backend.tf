terraform {
  backend "s3" {} # settings come from backend.hcl (git-ignored): terraform init -backend-config=backend.hcl
}
