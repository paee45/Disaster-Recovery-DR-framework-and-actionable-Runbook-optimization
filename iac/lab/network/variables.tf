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
variable "name" {
  description = "Prefix of every lab resource name (shared by network, eks, db, app)."
  type        = string
  default     = "dr-lab"
}
variable "vpc_cidr" {
  type    = string
  default = "10.60.0.0/16"
}
