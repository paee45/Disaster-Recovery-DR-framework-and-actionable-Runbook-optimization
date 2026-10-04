# compose/ files → S3 (the instance downloads them at boot); TLS + passwords → SSM SecureString (never in user data).
resource "aws_s3_bucket" "config" {
  bucket        = "${var.name}-config-${var.account_id}-${var.region}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "config" {
  bucket                  = aws_s3_bucket.config.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_object" "compose" {
  for_each = fileset("${path.module}/compose", "**")
  bucket   = aws_s3_bucket.config.id
  key      = "compose/${each.value}"
  source   = "${path.module}/compose/${each.value}"
  etag     = filemd5("${path.module}/compose/${each.value}")
}

resource "random_password" "admin" {
  length  = 20
  special = false
}

resource "random_password" "ldap_admin" {
  length  = 20
  special = false
}

locals {
  tls = { for f in ["cert.pem", "key.pem", "rootCA.pem"] : f => file(pathexpand("${var.tls_dir}/${f}")) }
  params = merge(
    { "admin-password" = random_password.admin.result, "ldap-admin-password" = random_password.ldap_admin.result },
    { for f, v in local.tls : replace(f, ".pem", "") => v }
  )
}

resource "aws_ssm_parameter" "this" {
  for_each = nonsensitive(toset(keys(local.params)))
  name     = "/${var.name}/terrakube/${each.value}"
  type     = "SecureString"
  tier     = "Standard"
  value    = local.params[each.value]
}
