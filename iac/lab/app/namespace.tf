resource "kubernetes_namespace_v1" "app" {
  metadata {
    name   = local.namespace
    labels = { reloader = "enabled" }
  }
}
