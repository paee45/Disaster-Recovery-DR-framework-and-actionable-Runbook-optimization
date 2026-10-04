variable "account_id" {
  description = "The SANDBOX account id. The AWS provider refuses to run in any other account."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be 12 digits."
  }
}
variable "aws_profile" {
  description = "Named AWS CLI profile (SSO) for the sandbox account."
  type        = string
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
variable "db_identifier" {
  type    = string
  default = "dr-lab-uat-pg"
}
variable "fixture" {
  description = "describe-db-instances .DBInstances[0] JSON (sanitised) the primary copies its settings from."
  type        = string
  default     = "../../../tests/local/fixtures/rds-primary-uat-like.json"
}
variable "deletion_protection" {
  description = "Lab default false so `terraform destroy` works (the real UAT has true)."
  type        = bool
  default     = false
}
variable "vpc_cidr" {
  type    = string
  default = "10.60.0.0/16"
}
variable "node_instance_type" {
  description = "EKS node. t3.small = smallest that fits (t3.micro allows only 4 pods: CNI, kube-proxy, CoreDNS, Reloader, 2 apps, seed job do not fit)."
  type        = string
  default     = "t3.small"
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
variable "kubeconfig_path" {
  description = "Separate kubeconfig for this env (the DR guard refuses foreign contexts and a current-context)."
  type        = string
  default     = "~/.kube/dr-uat.config"
}
variable "kube_context" {
  type    = string
  default = "dr-uat"
}
