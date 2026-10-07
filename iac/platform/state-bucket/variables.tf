variable "account_id" {
  description = "The account that owns this state bucket (Terraform refuses any other account). One bucket per account."
  type        = string
}
variable "aws_profile" {
  type = string
}
variable "region" {
  type    = string
  default = "ap-southeast-1"
}
variable "name_prefix" {
  description = "Bucket name = <name_prefix>-tfstate-<account_id>-<region> (S3 names are global; the account id keeps it unique)."
  type        = string
  default     = "dr"
}
variable "kms_key_arn" {
  description = "Empty = SSE-S3 (AES256). Set a customer KMS key for SSE-KMS; then add -backend-config=kms_key_id=... in iac/tf.sh too."
  type        = string
  default     = ""
}
variable "noncurrent_expiry_days" {
  description = "Old state versions are kept this long (rollback window), then deleted."
  type        = number
  default     = 90
}
