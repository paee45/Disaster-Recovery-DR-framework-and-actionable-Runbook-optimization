variable "state_bucket" {
  description = "S3 bucket holding the lab-aws state (output of iac/platform/state-bucket)."
  type        = string
}
variable "state_key" {
  type    = string
  default = "dr-framework/sandbox/lab-aws/terraform.tfstate"
}
variable "state_region" {
  type    = string
  default = "ap-southeast-1"
}
variable "state_profile" {
  description = "AWS profile to read that state. Empty = default credential chain (e.g. the Terrakube instance role)."
  type        = string
  default     = "pa_sandbox"
}
variable "namespace" {
  type    = string
  default = "app"
}
variable "secret_name" {
  description = "The app's DB Secret (SECRET_MODE=k8s). Two host keys, like the real UAT."
  type        = string
  default     = "db-creds"
}
variable "reloader_chart_version" {
  description = "Pin the Stakater Reloader chart (empty = latest; pin it once tested)."
  type        = string
  default     = ""
}
variable "env_file" {
  description = "Where to write the DR env profile (git-ignored)."
  type        = string
  default     = "../../../env/uat.env"
}
variable "seed_snapshot_id" {
  type    = string
  default = "dr-lab-seed"
}
