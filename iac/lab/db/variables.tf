variable "account_id" {
  description = "The SANDBOX account id. The AWS provider refuses to run in any other account."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be 12 digits."
  }
}
variable "aws_profile" {
  description = "Named AWS CLI profile (SSO) for the sandbox account. null = default credential chain (e.g. the Terrakube instance role)."
  type        = string
  default     = null
}
variable "region" {
  type    = string
  default = "ap-southeast-1"
}
variable "operator_cidr" {
  description = "Your public IP as a /32 (curl -s https://checkip.amazonaws.com). Only this address may reach Postgres from outside the VPC — the DR scripts run psql from your laptop."
  type        = string
  validation {
    condition     = can(cidrnetmask(var.operator_cidr)) && endswith(var.operator_cidr, "/32")
    error_message = "operator_cidr must be a single address, e.g. 203.0.113.10/32."
  }
}
variable "name" {
  description = "Prefix of every resource name."
  type        = string
  default     = "dr-lab"
}
variable "env" {
  description = "Which environment this DB plays (dev | uat | prod). One state per env; names carry the env, so all three can live in the sandbox at once."
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
variable "fixture" {
  description = "describe-db-instances .DBInstances[0] JSON (sanitised) the primary copies its settings from. Empty = tests/local/fixtures/rds-primary-<env>-like.json, falling back to the uat one until a dev/prod fixture exists."
  type        = string
  default     = ""
}
variable "deletion_protection" {
  description = "Lab default false so `terraform destroy` works (the real UAT has true)."
  type        = bool
  default     = false
}
variable "db_instance_class" {
  description = "Free-tier eligible by default. Empty = the fixture's class (the real UAT: db.t4g.small)."
  type        = string
  default     = "db.t4g.micro"
}
variable "performance_insights" {
  description = "Mirror the UAT's Performance Insights (fixture: on). Off by default for the micro class / free tier."
  type        = bool
  default     = false
}
