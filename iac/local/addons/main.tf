resource "kubernetes_namespace_v1" "app" {
  metadata {
    name   = "app"
    labels = { reloader = "enabled" }
  }
}

resource "kubernetes_namespace_v1" "reloader" {
  metadata {
    name = "reloader"
  }
}

resource "kubernetes_namespace_v1" "external_secrets" {
  count = var.enable_eso ? 1 : 0
  metadata {
    name = "external-secrets"
  }
}

resource "kubernetes_config_map_v1" "identity" {
  metadata {
    name      = "dr-cluster-identity"
    namespace = "kube-system"
  }

  data = {
    env     = "local"
    account = "000000000000"
    cluster = "dr-local-k3s"
    context = "dr-local"
  }
}

resource "helm_release" "external_secrets" {
  count            = var.enable_eso ? 1 : 0
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = "0.18.2"
  namespace        = kubernetes_namespace_v1.external_secrets[0].metadata[0].name
  create_namespace = false
  wait             = true
  atomic           = true
  timeout          = 600

  values = [yamlencode({
    installCRDs = true
    extraEnv = [
      {
        name  = "AWS_SECRETSMANAGER_ENDPOINT"
        value = "http://172.30.0.10:4566"
      },
      {
        name  = "AWS_STS_ENDPOINT"
        value = "http://172.30.0.10:4566"
      }
    ]
  })]
}

resource "helm_release" "reloader" {
  name             = "reloader"
  repository       = "https://stakater.github.io/stakater-charts"
  chart            = "reloader"
  version          = "2.2.18"
  namespace        = kubernetes_namespace_v1.reloader.metadata[0].name
  create_namespace = false
  wait             = true
  atomic           = true
  timeout          = 600

  values = [
    file("${path.module}/../../../automation/k8s/reloader-values.yaml"),
    yamlencode({
      reloader = {
        deployment = {
          env = {
            secret = {
              ALERT_ON_RELOAD       = "true"
              ALERT_WEBHOOK_URL     = "http://reloader-alert-sink.reloader.svc:8080/"
              ALERT_ADDITIONAL_INFO = "cluster=dr-local env=local"
            }
          }
        }
      }
    })
  ]
}