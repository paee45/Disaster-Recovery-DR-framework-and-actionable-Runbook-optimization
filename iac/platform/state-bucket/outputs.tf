output "bucket" { value = aws_s3_bucket.state.bucket }
output "region" { value = var.region }
output "next" {
  value = <<-EOT
    State bucket ready. Its own state moves into it on the next iac/tf.sh run; then move Terrakube's local state:
      iac/tf.sh platform/terrakube migrate
      bucket = "${aws_s3_bucket.state.bucket}"
  EOT
}
