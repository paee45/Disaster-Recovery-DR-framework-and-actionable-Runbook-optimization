output "bucket" { value = aws_s3_bucket.state.bucket }
output "region" { value = var.region }
output "next" {
  value = <<-EOT
    State bucket ready. Its own state moves into it on the next iac/tf.sh run. Any stack with a local
    terraform.tfstate and no state in S3 yet is copied in automatically on its next iac/tf.sh run.
      bucket = "${aws_s3_bucket.state.bucket}"
  EOT
}
