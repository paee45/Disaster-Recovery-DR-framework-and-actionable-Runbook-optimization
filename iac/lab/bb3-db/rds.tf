data "aws_subnet" "placement" {
  count = 2
  id    = local.net.public_subnet_ids[count.index]
}

resource "aws_security_group" "db_app" {
  name        = "${local.prefix}-db-app"
  description = "BB3 sandbox PostgreSQL from the shared sandbox VPC"
  vpc_id      = local.net.vpc_id
  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [local.net.vpc_cidr]
  }
  tags = { Name = "${local.prefix}-db-app" }

  lifecycle {
    precondition {
      condition     = can(cidrnetmask(local.net.vpc_cidr)) && local.net.vpc_cidr != "0.0.0.0/0"
      error_message = "Shared network must provide a restricted IPv4 VPC CIDR."
    }
  }
}

resource "aws_subnet" "private" {
  count                   = 2
  vpc_id                  = local.net.vpc_id
  availability_zone       = data.aws_subnet.placement[count.index].availability_zone
  cidr_block              = cidrsubnet(local.net.vpc_cidr, 8, 52 + 2 * index(["dev", "uat", "prod"], var.env) + count.index)
  map_public_ip_on_launch = false
  tags                    = { Name = "${local.prefix}-db-app${count.index + 1}" }
}

resource "aws_route_table" "private" {
  vpc_id = local.net.vpc_id
  route  = []
  tags   = { Name = "${local.prefix}-private" }
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_db_subnet_group" "this" {
  name       = "${local.prefix}-private-subnets"
  subnet_ids = aws_subnet.private[*].id
  lifecycle {
    precondition {
      condition     = alltrue([for subnet in data.aws_subnet.placement : subnet.vpc_id == local.net.vpc_id]) && data.aws_subnet.placement[0].availability_zone != data.aws_subnet.placement[1].availability_zone
      error_message = "DB subnets must belong to the shared sandbox VPC and occupy different AZs."
    }
  }
}

resource "aws_db_parameter_group" "this" {
  name   = "${local.prefix}-postgres17"
  family = "postgres17"
}

resource "random_password" "master" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "master" {
  name_prefix             = "${local.prefix}-master-"
  description             = "Disposable BB3 sandbox drill credentials; master user, do not reuse outside the lab"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "master" {
  secret_id = aws_secretsmanager_secret.master.id
  secret_string = jsonencode({
    DB_HOST         = aws_db_instance.primary.address
    DB_REPLICA_HOST = coalesce(one(aws_db_instance.replica[*].address), "")
    DB_NAME         = aws_db_instance.primary.db_name
    DB_USER         = aws_db_instance.primary.username
    DB_PASSWORD     = random_password.master.result
  })
}

resource "aws_db_instance" "primary" {
  identifier     = "${local.prefix}-primary-drill"
  engine         = "postgres"
  engine_version = "17.9"
  instance_class = var.db_instance_class
  db_name        = "beepbeep3"
  username       = "beepbeep"
  password       = random_password.master.result

  allocated_storage      = 20
  max_allocated_storage  = 100
  storage_type           = "gp3"
  storage_encrypted      = true
  availability_zone      = data.aws_subnet.placement[0].availability_zone
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db_app.id]
  parameter_group_name   = aws_db_parameter_group.this.name
  publicly_accessible    = false
  multi_az               = false

  backup_retention_period = var.backup_retention_period
  backup_window           = "18:00-18:30"
  maintenance_window      = "sun:19:00-sun:19:30"
  copy_tags_to_snapshot   = true
  deletion_protection     = false
  skip_final_snapshot     = true
  apply_immediately       = true
  tags                    = { Name = "${local.prefix}-primary-drill", Role = "primary", backup-plan = "${var.env}-daily" }
}

resource "aws_db_instance" "replica" {
  count                   = var.replica_enabled ? 1 : 0
  identifier              = "${local.prefix}-replica-drill"
  replicate_source_db     = aws_db_instance.primary.identifier
  instance_class          = var.replica_instance_class
  availability_zone       = data.aws_subnet.placement[1].availability_zone
  storage_encrypted       = true
  storage_type            = "gp3"
  max_allocated_storage   = 100
  vpc_security_group_ids  = [aws_security_group.db_app.id]
  parameter_group_name    = aws_db_parameter_group.this.name
  publicly_accessible     = false
  multi_az                = false
  backup_retention_period = 0
  copy_tags_to_snapshot   = true
  deletion_protection     = false
  skip_final_snapshot     = true
  apply_immediately       = true
  tags                    = { Name = "${local.prefix}-replica-drill", Role = "read-replica" }
}