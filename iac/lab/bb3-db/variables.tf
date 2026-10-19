variable "account_id" {
  description = "Sandbox account from ignored sandbox config; provider refuses other accounts."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be 12 digits."
  }
}

variable "aws_profile" {
  type    = string
  default = "lab_sandbox"
  validation {
    condition     = contains(["lab_sandbox", "pa_aws_sandbox"], var.aws_profile)
    error_message = "Only lab_sandbox (SSO) or pa_aws_sandbox (sandbox IAM user) is allowed."
  }
}

variable "region" {
  type    = string
  default = "ap-southeast-1"
  validation {
    condition     = var.region == "ap-southeast-1"
    error_message = "Only ap-southeast-1 is allowed."
  }
}

variable "state_bucket" {
  description = "Existing sandbox S3 state bucket, supplied by iac/tf.sh."
  type        = string
}

variable "env" {
  description = "Sandbox role only, never a real BB3 environment."
  type        = string
  validation {
    condition     = contains(["dev", "uat", "prod"], var.env)
    error_message = "env must be dev, uat or prod within the sandbox."
  }
}

variable "db_instance_class" {
  description = "Primary size; small is an optional sandbox override."
  type        = string
  default     = "db.t4g.micro"
  validation {
    condition     = contains(["db.t4g.micro", "db.t4g.small"], var.db_instance_class)
    error_message = "Primary class must be db.t4g.micro or db.t4g.small."
  }
}

variable "replica_instance_class" {
  type    = string
  default = "db.t4g.micro"
  validation {
    condition     = var.replica_instance_class == "db.t4g.micro"
    error_message = "Replica class must be db.t4g.micro."
  }
}

variable "replica_enabled" {
  type    = bool
  default = true
}

variable "backup_retention_period" {
  type    = number
  default = 7
  validation {
    condition     = var.backup_retention_period >= 7 && var.backup_retention_period <= 35 && floor(var.backup_retention_period) == var.backup_retention_period
    error_message = "Backup retention must be an integer from 7 to 35 days."
  }
}