output "env" { value = var.env }
output "db_identifier" { value = aws_db_instance.primary.identifier }
output "db_address" { value = aws_db_instance.primary.address }
output "db_port" { value = aws_db_instance.primary.port }
output "primary_az" { value = aws_db_instance.primary.availability_zone }
output "replica_identifier" { value = one(aws_db_instance.replica[*].identifier) }
output "replica_address" { value = one(aws_db_instance.replica[*].address) }
output "replica_az" { value = one(aws_db_instance.replica[*].availability_zone) }
output "master_secret_arn" { value = aws_secretsmanager_secret.master.arn }
output "recovery_constraints" {
  value = "A primary with a read replica cannot be stopped for fencing. Never automatically stop, delete or promote a replica to fence. A restored DB does not inherit the replica. Teardown must delete replica before primary. Real fencing and recovery RTO require separate validation; not certified here."
}