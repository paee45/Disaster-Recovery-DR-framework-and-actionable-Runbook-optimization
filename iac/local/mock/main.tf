locals {
  root        = abspath("${path.module}/../../..")
  state_dir   = "${local.root}/tests/local/.state"
  fixture     = var.fixture != "" ? var.fixture : "${local.root}/tests/local/fixtures/rds-primary-uat-like.json"
  fx          = jsondecode(file(local.fixture))
  family      = "postgres${split(".", local.fx.EngineVersion)[0]}"
  gp3big      = local.fx.StorageType == "gp3" && local.fx.AllocatedStorage >= 400
  needs_kms   = local.fx.StorageEncrypted || local.fx.PerformanceInsightsEnabled
  option_name = try([for group in local.fx.OptionGroupMemberships : group.OptionGroupName if !startswith(group.OptionGroupName, "default:")][0], null)
  db_port     = try(local.fx.Endpoint.Port, local.fx.DbInstancePort, 5432)
  tags = merge(
    { for tag in local.fx.TagList : tag.Key => tag.Value if !startswith(tag.Key, "aws:") },
    { app = "orders", owner = "sre-team", cost-center = "CC 1234 / retail", backup-plan = "local-daily" }
  )
}

resource "aws_vpc" "this" {
  cidr_block = "10.0.0.0/16"
}

resource "aws_subnet" "this" {
  count             = 3
  vpc_id            = aws_vpc.this.id
  cidr_block        = "10.0.${count.index + 1}.0/24"
  availability_zone = "eu-west-1${["a", "b", "c"][count.index]}"
}

resource "aws_security_group" "db" {
  count       = 3
  name        = "db-sg-${count.index + 1}"
  description = "db-sg-${count.index + 1}"
  vpc_id      = aws_vpc.this.id
}

resource "aws_security_group" "quarantine" {
  name        = "quarantine"
  description = "no inbound"
  vpc_id      = aws_vpc.this.id
}

resource "aws_db_subnet_group" "this" {
  name        = local.fx.DBSubnetGroup.DBSubnetGroupName
  description = local.fx.DBSubnetGroup.DBSubnetGroupDescription
  subnet_ids  = aws_subnet.this[*].id
}

resource "aws_db_parameter_group" "this" {
  name        = local.fx.DBParameterGroups[0].DBParameterGroupName
  family      = local.family
  description = "local"
}

resource "aws_iam_role" "rds_monitoring" {
  count = local.fx.MonitoringInterval > 0 ? 1 : 0
  name  = "rds-monitoring-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "monitoring.rds.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  count      = local.fx.MonitoringInterval > 0 ? 1 : 0
  role       = aws_iam_role.rds_monitoring[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

resource "aws_kms_key" "db" {
  count       = local.needs_kms ? 1 : 0
  description = "Local mock RDS storage and Performance Insights"
}

resource "aws_db_instance" "primary" {
  identifier     = "app-pg-local"
  engine         = local.fx.Engine
  engine_version = local.fx.EngineVersion
  instance_class = local.fx.DBInstanceClass
  username       = local.fx.MasterUsername
  password       = "masterpw"
  db_name        = try(local.fx.DBName, null)
  port           = local.db_port == 0 ? 5432 : local.db_port

  allocated_storage     = local.fx.AllocatedStorage
  max_allocated_storage = try(local.fx.MaxAllocatedStorage, null)
  storage_type          = local.fx.StorageType
  iops                  = startswith(local.fx.StorageType, "io") || local.gp3big ? try(local.fx.Iops, null) : null
  storage_throughput    = local.gp3big ? try(local.fx.StorageThroughput, null) : null
  storage_encrypted     = local.fx.StorageEncrypted
  kms_key_id            = local.fx.StorageEncrypted ? aws_kms_key.db[0].arn : null
  dedicated_log_volume  = local.fx.DedicatedLogVolume

  db_subnet_group_name      = aws_db_subnet_group.this.name
  vpc_security_group_ids    = aws_security_group.db[*].id
  parameter_group_name      = aws_db_parameter_group.this.name
  option_group_name         = local.option_name
  availability_zone         = local.fx.MultiAZ ? null : "eu-west-1${substr(local.fx.AvailabilityZone, -1, 1)}"
  publicly_accessible       = local.fx.PubliclyAccessible
  multi_az                  = local.fx.MultiAZ
  network_type              = local.fx.NetworkType
  customer_owned_ip_enabled = local.fx.CustomerOwnedIpEnabled
  ca_cert_identifier        = local.fx.CACertificateIdentifier

  backup_retention_period = local.fx.BackupRetentionPeriod
  backup_target           = local.fx.BackupTarget
  backup_window           = local.fx.PreferredBackupWindow
  maintenance_window      = local.fx.PreferredMaintenanceWindow
  copy_tags_to_snapshot   = local.fx.CopyTagsToSnapshot

  auto_minor_version_upgrade          = local.fx.AutoMinorVersionUpgrade
  iam_database_authentication_enabled = local.fx.IAMDatabaseAuthenticationEnabled
  enabled_cloudwatch_logs_exports     = local.fx.EnabledCloudwatchLogsExports
  engine_lifecycle_support            = local.fx.EngineLifecycleSupport
  license_model                       = local.fx.LicenseModel

  monitoring_interval                   = local.fx.MonitoringInterval
  monitoring_role_arn                   = local.fx.MonitoringInterval > 0 ? aws_iam_role.rds_monitoring[0].arn : null
  performance_insights_enabled          = local.fx.PerformanceInsightsEnabled
  performance_insights_kms_key_id       = local.fx.PerformanceInsightsEnabled ? aws_kms_key.db[0].arn : null
  performance_insights_retention_period = local.fx.PerformanceInsightsEnabled ? local.fx.PerformanceInsightsRetentionPeriod : null
  database_insights_mode                = try(local.fx.DatabaseInsightsMode, null)

  deletion_protection = false
  skip_final_snapshot = true
  apply_immediately   = true
  tags                = local.tags

  depends_on = [aws_iam_role_policy_attachment.rds_monitoring]
}

resource "aws_db_instance" "replica" {
  identifier                            = "app-pg-local-replica"
  replicate_source_db                   = aws_db_instance.primary.identifier
  instance_class                        = local.fx.DBInstanceClass
  publicly_accessible                   = local.fx.PubliclyAccessible
  vpc_security_group_ids                = aws_security_group.db[*].id
  skip_final_snapshot                   = true
  deletion_protection                   = false
  enabled_cloudwatch_logs_exports       = local.fx.EnabledCloudwatchLogsExports
  monitoring_interval                   = local.fx.MonitoringInterval
  monitoring_role_arn                   = local.fx.MonitoringInterval > 0 ? aws_iam_role.rds_monitoring[0].arn : null
  performance_insights_enabled          = local.fx.PerformanceInsightsEnabled
  performance_insights_kms_key_id       = local.fx.PerformanceInsightsEnabled ? aws_kms_key.db[0].arn : null
  performance_insights_retention_period = local.fx.PerformanceInsightsEnabled ? local.fx.PerformanceInsightsRetentionPeriod : null
  tags                                  = local.tags

}

resource "aws_db_snapshot" "walkthrough" {
  db_instance_identifier = aws_db_instance.primary.identifier
  db_snapshot_identifier = "app-pg-local-fixture"
}

resource "aws_db_snapshot" "daily_1d" {
  db_instance_identifier = aws_db_instance.primary.identifier
  db_snapshot_identifier = "app-pg-local-daily-1d"
}

resource "aws_db_snapshot" "daily_2d" {
  db_instance_identifier = aws_db_instance.primary.identifier
  db_snapshot_identifier = "app-pg-local-daily-2d"
}

resource "aws_secretsmanager_secret" "app" {
  name                    = "local/app/db"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "app" {
  secret_id = aws_secretsmanager_secret.app.id
  secret_string = jsonencode({
    engine               = "postgres"
    host                 = "172.30.0.21"
    port                 = 5432
    dbname               = "app"
    username             = "app_user"
    password             = "apppw-current"
    dbInstanceIdentifier = aws_db_instance.primary.identifier
  })
}

resource "aws_secretsmanager_secret" "master" {
  name                    = "local/app/db-master"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "master" {
  secret_id     = aws_secretsmanager_secret.master.id
  secret_string = jsonencode({ username = "postgres", password = "masterpw" })
}

resource "aws_s3_bucket" "evidence" {
  bucket        = "org-dr-evidence-000000000000"
  force_destroy = true
}