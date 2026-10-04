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
