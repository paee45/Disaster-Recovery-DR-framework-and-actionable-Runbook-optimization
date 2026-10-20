variable "bb3_secret_update_enabled" {
  description = "Enable the guarded endpoint-only SSM updater for the disposable sandbox secret."
  type        = bool
  default     = false
  validation {
    condition     = !var.bb3_secret_update_enabled || contains(["dev", "uat"], var.env)
    error_message = "Endpoint update testing is limited to sandbox dev/uat."
  }
}

resource "aws_iam_role" "secret_update" {
  count = var.bb3_secret_update_enabled ? 1 : 0
  name  = "${local.prefix}-secret-endpoints"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ssm.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = var.account_id }
        ArnLike      = { "aws:SourceArn" = "arn:aws:ssm:${var.region}:${var.account_id}:automation-execution/*" }
      }
    }]
  })
}

resource "aws_iam_role_policy" "secret_update" {
  count = var.bb3_secret_update_enabled ? 1 : 0
  name  = "endpoint-only-sandbox-secret"
  role  = aws_iam_role.secret_update[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["rds:DescribeDBInstances"]
      Resource = "*"
      Condition = {
        StringEquals = { "aws:RequestedRegion" = var.region }
      }
      }, {
      Effect = "Allow"
      Action = [
        "secretsmanager:DescribeSecret", "secretsmanager:GetSecretValue",
        "secretsmanager:PutSecretValue", "secretsmanager:UpdateSecretVersionStage"
      ]
      Resource = aws_secretsmanager_secret.master.arn
    }]
  })
}

resource "aws_ssm_document" "secret_update" {
  count           = var.bb3_secret_update_enabled ? 1 : 0
  name            = "BB3-${var.env}-UpdateDbSecretEndpoint"
  document_type   = "Automation"
  document_format = "YAML"
  content         = file("${path.module}/../../../automation/ssm/DR-UpdateDbSecretEndpoint.yaml")
}

output "secret_update_role_arn" {
  value = one(aws_iam_role.secret_update[*].arn)
}

output "secret_update_document" {
  value = one(aws_ssm_document.secret_update[*].name)
}

output "secret_update_document_version" {
  value = one(aws_ssm_document.secret_update[*].latest_version)
}