locals {
  manifest_directory = "${path.module}/../../../tests/local/k8s"
  manifest_files = toset([
    for filename in fileset(local.manifest_directory, "*.yaml") : filename
    if !var.direct_only || filename != "10-eso.yaml"
  ])
}

data "kubectl_file_documents" "fixtures" {
  for_each = local.manifest_files
  content  = file("${local.manifest_directory}/${each.value}")
}

locals {
  fixture_manifests = merge([
    for source in data.kubectl_file_documents.fixtures : source.manifests
  ]...)

  workload_manifests = {
    for identifier, document in local.fixture_manifests : identifier => document
    if (!var.direct_only || !contains(["Deployment", "StatefulSet", "CronJob", "Service"], yamldecode(document).kind) ||
      !contains(["app-a", "app-b", "app-c", "app-report"], yamldecode(document).metadata.name)) &&
    yamldecode(document).kind != "Namespace" && !(
      yamldecode(document).kind == "ConfigMap" &&
      try(yamldecode(document).metadata.namespace, "") == "kube-system" &&
      yamldecode(document).metadata.name == "dr-cluster-identity"
    )
  }
}

resource "kubectl_manifest" "fixture" {
  for_each = local.workload_manifests

  yaml_body        = each.value
  validate_schema  = true
  wait_for_rollout = true
}