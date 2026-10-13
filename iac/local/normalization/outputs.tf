output "active_primary" {
  value = aws_db_instance.active.identifier
}

output "active_primary_env_file" {
  value = local_file.active_primary_env.filename
}
