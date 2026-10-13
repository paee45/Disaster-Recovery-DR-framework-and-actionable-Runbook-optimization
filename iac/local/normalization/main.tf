locals {
  repository_root = abspath("${path.module}/../../..")
  state_dir       = "${local.repository_root}/tests/local/.state"
  baseline        = jsondecode(file(var.baseline_file))
  source          = local.baseline.instance
  gp3big          = local.source.StorageType == "gp3" && local.source.AllocatedStorage >= 400
  option_name     = try([for group in local.source.OptionGroupMemberships : group.OptionGroupName if !startswith(group.OptionGroupName, "default:")][0], null)
  source_tags     = { for tag in local.baseline.tags : tag.Key => tag.Value }
  tags = merge(local.source_tags, {
    "dr-restore"       = var.dr_id
    "dr-restored-from" = "${local.baseline.source}@${var.restore_time}"
  })
}

import {
  to = aws_db_instance.active
  id = var.restored_db_id
}

resource "aws_db_instance" "active" {
  identifier     = var.restored_db_id
  engine         = local.source.Engine
  engine_version = local.source.EngineVersion
  instance_class = local.source.DBInstanceClass
  username       = local.source.MasterUsername
  db_name        = try(local.source.DBName, null)
  port           = try(local.source.Endpoint.Port, local.source.DbInstancePort, 5432)

  allocated_storage     = local.source.AllocatedStorage
  max_allocated_storage = try(local.source.MaxAllocatedStorage, null)
  storage_type          = local.source.StorageType
  iops                  = startswith(local.source.StorageType, "io") || local.gp3big ? try(local.source.Iops, null) : null
  storage_throughput    = local.gp3big ? try(local.source.StorageThroughput, null) : null
  storage_encrypted     = local.source.StorageEncrypted
  kms_key_id            = local.source.StorageEncrypted ? try(local.source.KmsKeyId, null) : null
  dedicated_log_volume  = try(local.source.DedicatedLogVolume, false)

  db_subnet_group_name      = local.source.DBSubnetGroup.DBSubnetGroupName
  vpc_security_group_ids    = [for group in local.source.VpcSecurityGroups : group.VpcSecurityGroupId]
  parameter_group_name      = local.source.DBParameterGroups[0].DBParameterGroupName
  option_group_name         = local.option_name
  availability_zone         = local.source.MultiAZ ? null : local.source.AvailabilityZone
  publicly_accessible       = local.source.PubliclyAccessible
  multi_az                  = local.source.MultiAZ
  network_type              = local.source.NetworkType
  customer_owned_ip_enabled = try(local.source.CustomerOwnedIpEnabled, false)
  ca_cert_identifier        = local.source.CACertificateIdentifier

  backup_retention_period = local.source.BackupRetentionPeriod
  backup_target           = local.source.BackupTarget
  backup_window           = local.source.PreferredBackupWindow
  maintenance_window      = local.source.PreferredMaintenanceWindow
  copy_tags_to_snapshot   = local.source.CopyTagsToSnapshot

  auto_minor_version_upgrade          = local.source.AutoMinorVersionUpgrade
  iam_database_authentication_enabled = local.source.IAMDatabaseAuthenticationEnabled
  enabled_cloudwatch_logs_exports     = local.source.EnabledCloudwatchLogsExports
  engine_lifecycle_support            = local.source.EngineLifecycleSupport
  license_model                       = local.source.LicenseModel

  monitoring_interval                   = local.source.MonitoringInterval
  monitoring_role_arn                   = local.source.MonitoringRoleArn
  performance_insights_enabled          = local.source.PerformanceInsightsEnabled
  performance_insights_kms_key_id       = local.source.PerformanceInsightsKMSKeyId
  performance_insights_retention_period = local.source.PerformanceInsightsRetentionPeriod
  database_insights_mode                = local.source.DatabaseInsightsMode

  deletion_protection = true
  skip_final_snapshot = true
  tags                = local.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "local_file" "active_primary_env" {
  filename        = "${local.state_dir}/normalization.env"
  file_permission = "0600"
  content         = "export PRIMARY_DB=${aws_db_instance.active.identifier}\n"
}
