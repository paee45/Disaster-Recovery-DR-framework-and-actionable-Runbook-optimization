output "quarantine_sg" {
  value = aws_security_group.quarantine.id
}

output "local_env" {
  value = local_file.local_env.filename
}

output "aws_config" {
  value = local_file.aws_config.filename
}

output "aws_credentials" {
  value = local_sensitive_file.aws_credentials.filename
}

output "endpoint_map" {
  value = local_file.endpoint_map.filename
}

output "primary_db" {
  value = aws_db_instance.primary.identifier
}

output "replica_db" {
  value = aws_db_instance.replica.identifier
}