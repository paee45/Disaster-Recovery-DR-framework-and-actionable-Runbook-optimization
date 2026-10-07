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
  type    = string
  default = "dr-lab"
}
variable "state_bucket" {
  description = "State bucket (output of iac/platform/state-bucket); iac/tf.sh sets it from sandbox.env."
  type        = string
}
variable "node_instance_type" {
  description = "EKS node. t3.small = smallest that fits (t3.micro allows only 4 pods: CNI, kube-proxy, CoreDNS, Reloader, 2 apps, seed job do not fit)."
  type        = string
  default     = "t3.small"
}
variable "node_desired_size" {
  description = "Worker nodes. 0 = park the cluster (no node cost; the control plane still bills ~0.10 USD/h until destroy). Apply again with 1 to resume."
  type        = number
  default     = 1
}
variable "envs" {
  description = "One kubeconfig per env, each with ONE context dr-<env> to this shared cluster (the DR guard refuses foreign contexts and a current-context)."
  type        = list(string)
  default     = ["dev", "uat", "prod"]
}
variable "kubeconfig_dir" {
  type    = string
  default = "~/.kube"
}
