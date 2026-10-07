output "bucket" { value = aws_s3_bucket.state.bucket }
output "region" { value = var.region }
output "next" {
  value = <<-EOT
    Put these in each stack's backend.hcl (copy backend.hcl.example), then: terraform init -backend-config=backend.hcl -migrate-state
      bucket = "${aws_s3_bucket.state.bucket}"
      region = "${var.region}"
  EOT
}
