# App credentials: random password, stored only in the K8s Secret (and in this Terraform state — keep it local/private).
resource "random_password" "app" {
  length  = 24
  special = false
}

# The app Secret. The DR cutover CHANGES the host keys (and adds ledger annotations) — Terraform must not undo that,
# so it only creates the Secret and then ignores its data.
resource "kubernetes_secret_v1" "db" {
  metadata {
    name      = var.secret_name
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }
  data = {
    POSTGRES_DB_HOST1    = local.a.db_address
    POSTGRES_DB_HOST2    = local.a.db_address
    POSTGRES_DB_PORT     = tostring(local.a.db_port)
    POSTGRES_DB_NAME     = "app"
    POSTGRES_DB_USER     = "app_user"
    POSTGRES_DB_PASSWORD = random_password.app.result
  }
  lifecycle { ignore_changes = [data, metadata[0].annotations, metadata[0].labels] }
}

# Seed runs INSIDE the cluster (VPC → RDS), as the RDS master user read from Secrets Manager. Idempotent SQL.
data "aws_secretsmanager_secret_version" "master" {
  secret_id = local.a.master_secret_arn
}

resource "kubernetes_secret_v1" "seed" {
  metadata {
    name      = "dr-lab-seed"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }
  data = {
    PGHOST     = local.a.db_address
    PGPORT     = tostring(local.a.db_port)
    PGUSER     = jsondecode(data.aws_secretsmanager_secret_version.master.secret_string).username
    PGPASSWORD = jsondecode(data.aws_secretsmanager_secret_version.master.secret_string).password
    APP_PW     = random_password.app.result
    "seed.sql" = file("${path.module}/seed.sql")
  }
}

resource "kubernetes_job_v1" "seed" {
  metadata {
    name      = "dr-lab-seed"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }
  spec {
    backoff_limit = 4
    template {
      metadata {}
      spec {
        restart_policy = "Never"
        container {
          name    = "seed"
          image   = "postgres:16-alpine"
          command = ["/bin/sh", "-c", "PGSSLMODE=require PGDATABASE=postgres psql -X -v ON_ERROR_STOP=1 -v pw=\"$APP_PW\" -f /seed/seed.sql"]
          env_from {
            secret_ref { name = kubernetes_secret_v1.seed.metadata[0].name }
          }
          volume_mount {
            name       = "seed"
            mount_path = "/seed"
          }
        }
        volume {
          name = "seed"
          secret {
            secret_name = kubernetes_secret_v1.seed.metadata[0].name
            items {
              key  = "seed.sql"
              path = "seed.sql"
            }
          }
        }
      }
    }
  }
  wait_for_completion = true
  timeouts { create = "10m" }
}

# Manual snapshot AFTER the seed: the restore drill uses it (the automated snapshot predates the seed).
resource "aws_db_snapshot" "seed" {
  db_instance_identifier = local.a.db_identifier
  db_snapshot_identifier = var.seed_snapshot_id
  depends_on             = [kubernetes_job_v1.seed]
}
