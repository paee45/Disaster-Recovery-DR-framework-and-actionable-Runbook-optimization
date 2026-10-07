terraform {
  required_version = ">= 1.10"
  required_providers {
    terrakube = { source = "terrakube-io/terrakube" }
  }
  # Runs from the Mac (iac/tf.sh platform/terrakube-config apply) with the SSM tunnel to Terrakube open and an API
  # token from Terrakube (Settings > Tokens) in TF_VAR_terrakube_token. Terrakube cannot create its own organization.
}

provider "terrakube" {
  endpoint = var.terrakube_endpoint
  token    = var.terrakube_token
}
