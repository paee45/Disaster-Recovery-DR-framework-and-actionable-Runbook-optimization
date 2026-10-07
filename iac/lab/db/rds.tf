# The primary copies its settings from the sanitised UAT describe (same source the local tests use). Network ids,
# parameter group and monitoring role are the lab's own. Restores made by the DR scripts are NOT in this state:
# delete them first (runbook XF-S04) or `terraform destroy` cannot remove the subnet group / security groups.
locals {
  fixture_dir = "${path.module}/../../../tests/local/fixtures"
  fixture_env = "${local.fixture_dir}/rds-primary-${var.env}-like.json"
  fixture     = var.fixture != "" ? var.fixture : (fileexists(local.fixture_env) ? local.fixture_env : "${local.fixture_dir}/rds-primary-uat-like.json")
  fx          = jsondecode(file(local.fixture))
  p           = "${var.name}-${var.env}" # every name below carries the env, so dev/uat/prod coexist in one account
  db_id       = "${local.p}-pg"
  family      = "postgres${split(".", local.fx.EngineVersion)[0]}"
  gp3big      = local.fx.StorageType == "gp3" && local.fx.AllocatedStorage >= 400
}

# Three SGs like the real UAT: app (from the VPC = EKS pods), admin (operator /32 only), monitoring (placeholder).
resource "aws_security_group" "db_app" {
  name        = "${local.p}-db-app"
  description = "DR lab: Postgres from inside the VPC (EKS nodes)"
  vpc_id      = local.net.vpc_id
  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [local.net.vpc_cidr]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${local.p}-db-app" }
}

resource "aws_security_group" "db_admin" {
  name        = "${local.p}-db-admin"
  description = "DR lab: Postgres from the operator laptop only"
  vpc_id      = local.net.vpc_id
  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.operator_cidr]
  }
  tags = { Name = "${local.p}-db-admin" }
}

resource "aws_security_group" "db_monitoring" {
  name        = "${local.p}-db-monitoring"
  description = "DR lab: monitoring placeholder (no rules)"
  vpc_id      = local.net.vpc_id
  tags        = { Name = "${local.p}-db-monitoring" }
}

resource "aws_security_group" "quarantine" {
  name        = "${local.p}-quarantine"
  description = "DR lab: CP-04 F2 quarantine (no ingress, no egress)"
  vpc_id      = local.net.vpc_id
  tags        = { Name = "${local.p}-quarantine" }
}

resource "aws_db_subnet_group" "this" {
  name       = "${local.p}-db-subnets"
  subnet_ids = local.net.public_subnet_ids
}

resource "aws_db_parameter_group" "this" {
  name   = "${local.p}-${local.family}"
  family = local.family
}

resource "aws_iam_role" "rds_monitoring" {
  name = "${local.p}-rds-monitoring"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "monitoring.rds.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

resource "aws_db_instance" "primary" {
  identifier     = local.db_id
  engine         = local.fx.Engine
  engine_version = local.fx.EngineVersion
  instance_class = var.db_instance_class != "" ? var.db_instance_class : local.fx.DBInstanceClass
  username       = local.fx.MasterUsername
  # RDS keeps the master password in Secrets Manager (MASTER_SECRET_ID); Terraform never sees it.
  manage_master_user_password = true

  allocated_storage     = local.fx.AllocatedStorage
  max_allocated_storage = try(local.fx.MaxAllocatedStorage, null)
  storage_type          = local.fx.StorageType
  iops                  = local.gp3big ? local.fx.Iops : null
  storage_throughput    = local.gp3big ? local.fx.StorageThroughput : null
  storage_encrypted     = local.fx.StorageEncrypted

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db_app.id, aws_security_group.db_admin.id, aws_security_group.db_monitoring.id]
  parameter_group_name   = aws_db_parameter_group.this.name
  publicly_accessible    = true # LAB ONLY (reachable from operator_cidr only); the real UAT is private
  multi_az               = local.fx.MultiAZ
  network_type           = local.fx.NetworkType
  ca_cert_identifier     = local.fx.CACertificateIdentifier

  backup_retention_period  = local.fx.BackupRetentionPeriod
  backup_window            = local.fx.PreferredBackupWindow
  maintenance_window       = local.fx.PreferredMaintenanceWindow
  copy_tags_to_snapshot    = local.fx.CopyTagsToSnapshot
  delete_automated_backups = true

  auto_minor_version_upgrade          = local.fx.AutoMinorVersionUpgrade
  iam_database_authentication_enabled = local.fx.IAMDatabaseAuthenticationEnabled
  enabled_cloudwatch_logs_exports     = local.fx.EnabledCloudwatchLogsExports
  engine_lifecycle_support            = local.fx.EngineLifecycleSupport
  license_model                       = local.fx.LicenseModel

  monitoring_interval                   = local.fx.MonitoringInterval
  monitoring_role_arn                   = local.fx.MonitoringInterval > 0 ? aws_iam_role.rds_monitoring.arn : null
  performance_insights_enabled          = var.performance_insights && local.fx.PerformanceInsightsEnabled
  performance_insights_retention_period = var.performance_insights && local.fx.PerformanceInsightsEnabled ? local.fx.PerformanceInsightsRetentionPeriod : null
  database_insights_mode                = try(local.fx.DatabaseInsightsMode, null)

  deletion_protection = var.deletion_protection
  skip_final_snapshot = true
  apply_immediately   = true

  tags = { app = "dr-lab", owner = "sre-team", backup-plan = "${var.env}-daily" }

  depends_on = [aws_iam_role_policy_attachment.rds_monitoring]
}
