# Two sample consumers of the Secret, like the real UAT: lab-app-1 reads HOST1 and is Reloader-annotated;
# lab-app-2 reads HOST2 and is NOT annotated (the DR stale check must find it). Each keeps a session open with
# application_name=lab-app-N, so `dr-verify.sh connections` shows which DB it uses.
locals {
  apps = { "lab-app-1" = { key = "POSTGRES_DB_HOST1", reloader = true, order = "2" }, "lab-app-2" = { key = "POSTGRES_DB_HOST2", reloader = false, order = "3" } }
}

resource "kubernetes_deployment_v1" "app" {
  for_each = local.apps
  metadata {
    name        = each.key
    namespace   = kubernetes_namespace_v1.app.metadata[0].name
    labels      = { app = each.key, "dr.example.com/db-consumer" = "true", "dr.example.com/restart-order" = each.value.order }
    annotations = each.value.reloader ? { "secret.reloader.stakater.com/reload" = var.secret_name } : {}
  }
  spec {
    replicas = 1
    selector { match_labels = { app = each.key } }
    template {
      metadata { labels = { app = each.key } }
      spec {
        termination_grace_period_seconds = 2
        container {
          name    = "app"
          image   = "postgres:16-alpine"
          command = ["/bin/sh", "-c"]
          args = [<<-SH
            echo "start host=$${${each.value.key}}"
            while true; do
              PGPASSWORD="$POSTGRES_DB_PASSWORD" psql "host=$${${each.value.key}} port=$POSTGRES_DB_PORT dbname=$POSTGRES_DB_NAME user=$POSTGRES_DB_USER sslmode=require connect_timeout=5 application_name=${each.key}" \
                -XAtqc "select pg_sleep(30)" >/dev/null 2>&1 || { echo "db error on $${${each.value.key}}"; sleep 3; }
            done
          SH
          ]
          env_from {
            secret_ref { name = kubernetes_secret_v1.db.metadata[0].name }
          }
          resources {
            requests = { cpu = "10m", memory = "32Mi" }
          }
        }
      }
    }
  }
  # Reloader restarts pods by patching a pod-template annotation; the DR scripts restart via `rollout restart`.
  lifecycle { ignore_changes = [spec[0].template[0].metadata[0].annotations] }
  depends_on = [kubernetes_job_v1.seed]
}
