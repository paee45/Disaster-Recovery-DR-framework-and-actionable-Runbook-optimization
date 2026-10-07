variable "terrakube_endpoint" {
  description = "Terrakube API through the SSM tunnel (iac/platform/terrakube output 'tunnel')."
  type        = string
  default     = "https://terrakube-api.platform.local"
}
variable "terrakube_token" {
  description = "Terrakube API token (UI: user menu > Tokens). Put it in iac/sandbox.env as TF_VAR_terrakube_token."
  type        = string
  sensitive   = true
}
variable "account_id" {
  description = "The SANDBOX account id; passed to every lab workspace (their AWS provider refuses any other account)."
  type        = string
}
variable "region" {
  type    = string
  default = "ap-southeast-1"
}
variable "state_bucket" {
  description = "State bucket (output of iac/platform/state-bucket); every workspace keeps its state there."
  type        = string
}
variable "operator_cidr" {
  description = "Your public IP /32 for the DB admin security group; iac/tf.sh fills it in."
  type        = string
}
variable "repository" {
  description = "Git repo Terrakube clones for every run. A private repo needs a Terrakube VCS connection or SSH key added to the workspaces."
  type        = string
  default     = "https://github.com/paee45/Disaster-Recovery-DR-framework-and-actionable-Runbook-optimization.git"
}
variable "branch" {
  description = "Branch (or tag) the workspaces follow. A push changes what the next run deploys."
  type        = string
  default     = "claude/enterprise-dr-rds-runbook-ksy0q8"
}
variable "terraform_version" {
  description = "Terraform CLI version the executor downloads (>= 1.10: S3 native state locking)."
  type        = string
  default     = "1.15.2"
}
variable "organization" {
  type    = string
  default = "dr-lab"
}
variable "envs" {
  description = "Environments that get a db and an app workspace (all share the one lab cluster)."
  type        = list(string)
  default     = ["dev", "uat", "prod"]
}
variable "approver_team" {
  description = "Terrakube team that approves a plan before apply/destroy (LDAP group from compose/ldif)."
  type        = string
  default     = "TERRAKUBE_ADMIN"
}
