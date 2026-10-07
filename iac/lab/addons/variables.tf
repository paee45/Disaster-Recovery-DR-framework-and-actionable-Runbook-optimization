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
variable "state_bucket" {
  description = "State bucket (output of iac/platform/state-bucket); iac/tf.sh sets it from sandbox.env."
  type        = string
}
variable "reloader_chart_version" {
  description = "Pin the Stakater Reloader chart (empty = latest; pin it once tested)."
  type        = string
  default     = ""
}
variable "identity_env" {
  description = "The ONE env this shared cluster identifies as (kube-system/dr-cluster-identity). Other envs on it use REQUIRE_CLUSTER_IDENTITY=false."
  type        = string
  default     = "uat"
}
