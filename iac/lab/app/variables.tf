variable "account_id" {
  description = "The SANDBOX account id. The AWS provider refuses to run in any other account."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be 12 digits."
  }
}
variable "aws_profile" {
  description = "Named AWS CLI profile (SSO). null = default credential chain (e.g. the Terrakube instance role)."
  type        = string
  default     = null
}
variable "region" {
  type    = string
  default = "ap-southeast-1"
}
variable "env" {
  description = "Which environment this app namespace plays (dev | uat | prod); must match the lab/db state of the same env."
  type        = string
  validation {
    condition     = contains(["dev", "uat", "prod"], var.env)
    error_message = "env must be dev, uat or prod."
  }
}
variable "state_bucket" {
  description = "State bucket (output of iac/platform/state-bucket); iac/tf.sh sets it from sandbox.env."
  type        = string
}
variable "namespace" {
  description = "Empty = app for uat (like the real UAT), app-<env> for the others (they share one cluster)."
  type        = string
  default     = ""
}
variable "secret_name" {
  description = "The app's DB Secret (SECRET_MODE=k8s). Two host keys, like the real UAT."
  type        = string
  default     = "db-creds"
}
variable "cluster_identity_env" {
  description = "The env the shared cluster identifies as (lab/addons identity_env). Other envs get REQUIRE_CLUSTER_IDENTITY=false in their env file."
  type        = string
  default     = "uat"
}
variable "env_file" {
  description = "Where to write the DR env profile (git-ignored). Empty = env/<env>.env in the repo."
  type        = string
  default     = ""
}
variable "seed_snapshot_id" {
  description = "Empty = dr-lab-<env>-seed."
  type        = string
  default     = ""
}
