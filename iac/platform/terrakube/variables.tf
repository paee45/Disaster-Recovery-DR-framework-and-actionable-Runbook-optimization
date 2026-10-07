variable "account_id" {
  description = "The sandbox account id (Terraform refuses any other account)."
  type        = string
}
variable "aws_profile" {
  type = string
}
variable "region" {
  type    = string
  default = "ap-southeast-1"
}
variable "name" {
  type    = string
  default = "dr-platform"
}
variable "instance_type" {
  description = "t4g.small (2 GB) works only with the memory caps + swap in compose/; t4g.medium (4 GB) is comfortable. Graviton (t4g/*g) → arm64 AMI, others → x86_64."
  type        = string
  default     = "t4g.small"
}
variable "swap_gb" {
  type    = number
  default = 2
}
variable "root_volume_gb" {
  type    = number
  default = 30
}
variable "terrakube_version" {
  description = "Image tag of azbuilder/* (compose/ is adapted from the same release)."
  type        = string
  default     = "2.33.2"
}
variable "silo_version" {
  description = "pgsty/silo (MinIO-compatible storage) image tag."
  type        = string
  default     = "RELEASE.2026-09-16T00-00-00Z"
}
variable "tls_dir" {
  description = "Folder with cert.pem, key.pem, rootCA.pem made by mkcert on your Mac (see README)."
  type        = string
  default     = "~/.terrakube-tls"
}
variable "executor_admin" {
  description = "Give the instance role AdministratorAccess so Terrakube workspaces can build labs in THIS sandbox account without stored keys. false = UI only; add credentials per workspace yourself."
  type        = bool
  default     = true
}
variable "vpc_cidr" {
  type    = string
  default = "10.70.0.0/24"
}
variable "running" {
  description = "true = the instance runs; false = stopped (compute cost 0, disk + data kept). Apply from the Mac (iac/tf.sh platform/terrakube apply -var running=false) — Terrakube cannot stop the host it runs on."
  type        = bool
  default     = true
}
