output "env" { value = var.env }
output "db_identifier" { value = aws_db_instance.primary.identifier }
output "db_address" { value = aws_db_instance.primary.address }
output "db_port" { value = aws_db_instance.primary.port }
output "multi_az" { value = aws_db_instance.primary.multi_az }
output "master_secret_arn" { value = aws_db_instance.primary.master_user_secret[0].secret_arn }
output "quarantine_sg" { value = aws_security_group.quarantine.id }
output "evidence_bucket" { value = aws_s3_bucket.evidence.bucket }
