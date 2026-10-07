# Reloader exactly as the repo recommends (automation/k8s/reloader-values.yaml: HA, watches namespaces labelled
# reloader=enabled, annotations strategy, metrics).
resource "helm_release" "reloader" {
  name             = "reloader"
  repository       = "https://stakater.github.io/stakater-charts"
  chart            = "reloader"
  version          = var.reloader_chart_version == "" ? null : var.reloader_chart_version
  namespace        = "reloader"
  create_namespace = true
  values           = [file("${path.module}/../../../automation/k8s/reloader-values.yaml")]
  wait             = true
  timeout          = 300
}

# What dr_guard checks before ANY action: this cluster says env=<identity_env> and the expected account.
resource "kubernetes_config_map_v1" "identity" {
  metadata {
    name      = "dr-cluster-identity"
    namespace = "kube-system"
  }
  data = { env = var.identity_env, account = var.account_id, cluster = local.eks.eks_cluster_name }
}
